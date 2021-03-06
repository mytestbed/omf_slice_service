require 'omf/slice_service/resource'
require 'omf-sfa/resource/oresource'
require 'omf-sfa/util/graph_json'
require 'time'
require 'open-uri'

module OMF::SliceService::Resource
  class UnknownAuthorityException < OMF::SliceService::SliceServiceException; end
  class DiscardedSliverException < OMF::SliceService::SliceServiceException; end

  # This class represents a sliver in the system.
  #
  class Sliver < OMF::SFA::Resource::OResource
    RSPEC3_NS = "http://www.geni.net/resources/rspec/3"

    STATUS_CHECK_INTERVAL = 60 # after what time should we check again for sliver status
    STATUS_MIN_CHECK_INTERVAL = 20 # minimum time between status checks


    oproperty :status, String
    oproperty :status_checked_at, DataMapper::Property::Time
    oproperty :resources, Object
    oproperty :manifest, String  # actually XML
    oproperty :log_url, String # URL provided by AM to obtain more information
    oproperty :expires_at, DataMapper::Property::Time
    oproperty :created_at, DataMapper::Property::Time
    oproperty :provisioned_at, DataMapper::Property::Time
    oproperty :description, String
    oproperty :rspec, String
    oproperty :slice, :reference, type: :slice
    oproperty :authority, :reference, type: :suthority
    oproperty :progress, String, :functional => false

    oproperty :slice_member, :reference, type: :slice_member # TODO: Security alert - keep around for checking status

    def self.create_for_component_manager(cm_urn, rspec, slice_member, req_promise = nil)
      unless authority = Authority.first(urn: cm_urn)
        warn "Trying to create sliver on unknown authority '#{cm_urn}'"
        raise UnknownAuthorityException.new(cm_urn)
      end
      slice = slice_member.slice
      name = authority.name || authority.urn
      sliver = self.create(name: name, authority: authority, slice: slice_member.slice, status: 'provisioning')
      sliver.slice_member = slice_member # TODO: Security alert

      slice.progresses.clear # remove prior sliver progress as we are going to change state
      _speaks_for = Thread.current[:speaks_for]
      Task::CreateSliver(sliver, rspec, slice_member).on_success do |reply|
        Thread.current[:speaks_for] = _speaks_for
        sliver.provisioned_at = Time.now
        sliver.progress "Status changed to 'provisioned'"
        sliver.manifest = reply[:manifest]
        if log_url = reply[:err_url]
          sliver.log_url = log_url
        end
        sliver.status = 'provisioned'
        sliver.status(true) # force SliverStatus
      end.on_error do |err_code, msg|
        error ">>>>>>>>>>>>>>>>>>>>SLIVER ERRRO >>>> #{msg} - #{err_code}"
        sliver.progress "ERROR: #{msg} - #{err_code}"
        sliver.status = 'error:' + msg.to_s
        sliver.release
      end.on_always do
        sliver.save
      end.on_progress do |ts, m|
        sliver.progress(m, ts)
        sliver.save
      end.on_progress(req_promise, cm_urn)
      sliver
    end

    # Release this resource and the provisioned resource as well
    def release!(slice_member)
      self.status == 'releasing'
      self.save
      Task::DeleteSliver(self, slice_member).on_always do
        release
      end.on_progress {|ts, m| self.progress(m, ts) }
    end

    def release
      self.status == 'released'
      self.save
    end

    alias :_status :status
    def status(refresh = false)
      promise =  OMF::SFA::Util::Promise.new('SliverStatus')

      #return promise.resolve 'provisioning' unless self.provisioned?
      return promise.resolve 'released' if released?

      return @status_promise if @status_promise

      min_time = 30 # make sure we don't overload the server here
      check_interval = refresh ? STATUS_MIN_CHECK_INTERVAL : STATUS_CHECK_INTERVAL
      if (Time.now - (self.status_checked_at || 0)).to_i > check_interval
        @status_promise = promise # pending
        self.status_checked_at = Time.now
        _speaks_for = Thread.current[:speaks_for]
        OMF::SliceService::Task::SliverStatus(self, self.slice_member).on_success do |res|
          Thread.current[:speaks_for] = _speaks_for
          ready_count = 0
          error_count = 0
          if mf = self.manifest
            manifest = Nokogiri::XML.parse(mf)
          end
          resources = self.resources ||= {}
          res['geni_resources'].map do |r|
            unless client_id = r["geni_client_id"]
              warn "SliverStatus returns resource without 'client_id' - #{r}"
              next
            end
            ri = resources[client_id] ||= {}
            ri['client_id'] = client_id
            case status = ri['status'] = r["geni_status"]
            when 'ready'
              ready_count += 1
            else
              error_count += 1
            end
            #ssh_login = _parse_ssh_login(r["geni_client_id"], manifest)
            ri['urn'] = r["geni_urn"]
            ri['error'] = r["geni_error"] if r["geni_error"] && !r["geni_error"].empty?
            #res[:ssh_login] = ssh_login if ssh_login
            #res
          end

          self.resources = resources

          curr_status = self._status
          if ready_count + error_count > 0
            # we know something of at least one resource
            resource_count = resources.size
            all_ready = (resource_count == ready_count)
            self.status = status = all_ready ? 'ready' : "partial: #{ready_count} of #{resource_count}"
            if status != curr_status
              self.progress "Status changed to '#{status}'"
            end
            unless all_ready
              # force re-check
              EM.add_timer(STATUS_MIN_CHECK_INTERVAL + 1) do
                status(true)
              end
            end
          end
          if expires_s = res["pg_expires"]
            self.expires_at = Time.parse(expires_s)
          end
          self.save
          @status_promise = nil
          promise.resolve(status)
        end.on_error do |code, ex|
          warn ">>>> Obtaining Sliver status FAILED: #{ex}"
          @status_promise = nil
          if ex.is_a? OMF::SliceService::Task::SliverNotFoundException
            self.progress "Can no longer find sliver on AM - #{ex}"
            self.release
            promise.resolve(status)
          else
            promise.reject(code, ex)
          end
        end.on_progress(promise)
      else
        promise.resolve self._status
      end
      promise
    end

    alias :_status= :status=
    def status=(status)
      self._status = status
      if @status_handlers
        @status_handlers.each do |block|
          begin
            block.call(status)
          rescue Exception => ex
            warn "(#{self.urn}) Exception while calling '#{block}' - #{ex}"
            debug ex.backtrace.join("\n\t")
          end
        end
      end
      status
    end

    alias :_manifest= :manifest=
    def manifest=(manifest)
      self._manifest = manifest

      return nil unless manifest
      unless manifest.is_a? Nokogiri::XML::Document
        manifest = Nokogiri::XML.parse(manifest)
      end

      resources = self.resources || {}
      slice_postfix = self.slice.slice_postfix
      manifest.root.xpath('n:*[@client_id]', n: RSPEC3_NS).each do |r_el|
        client_id = r_el['client_id']
        puts ">>>> #{client_id} -- #{resources.class} -- #{r_el}"
        ri = resources[client_id] ||= {}
        ri['client_id'] =  client_id
        ri['status'] ||= 'unknown' # set it to something initially
        ri['type'] = r_el.name
        ri['omf_id'] = client_id + slice_postfix
        ri['sliver_id'] = r_el['sliver_id']
        if st_el = r_el.xpath('n:sliver_type', n: RSPEC3_NS)[0]
          ri['node_type'] = st_el['name']
        end
        if login = r_el.xpath('n:services/n:login[@authentication="ssh-keys"]', n: RSPEC3_NS)[0]
          ri['ssh_login'] = {
            hostname: login['hostname'],
            port: login['port']
          }
        end
        interfaces = ri['interfaces'] || {}
        # NODES
        r_el.xpath('n:interface', n: RSPEC3_NS).map do |inf_el|
          client_id = inf_el['client_id']
          ii = interfaces[client_id] ||= {}
          ii['client_id'] = client_id
          ii['sliver_id'] = inf_el['sliver_id']
          if mac = inf_el['mac_address']
            ii['mac_address'] = mac
          end
          ii['ip'] = inf_el.xpath('n:ip', n: RSPEC3_NS).map do |ip_el|
            {address: ip_el['address'], type: ip_el['type']}
          end
        end
        # LINKS
        r_el.xpath('n:interface_ref', n: RSPEC3_NS).map do |inf_el|
          client_id = inf_el['client_id']
          ii = interfaces[client_id] ||= {}
          ii['client_id'] = client_id
          ii['sliver_id'] = inf_el['sliver_id']
        end
        ri['interfaces'] = interfaces unless interfaces.empty?
      end
      self.resources = resources
      self.save

      #doc.xpath( '/n:rspec/n:*[@client_id]', n: NS)[1].to_s
      manifest
    end


    # Call 'block' whenever the status of this sliver changes
    #
    # NOTE: This only applies to this instance and is not persisted.
    # This means that if this resource is retrieved in a different context
    # which changes the status, 'block' may not be called.
    #
    def on_status(&block)
      (@status_handlers ||= []) << block
      self
    end

    def _parse_ssh_login(client_id, manifest)
      return nil unless client_id && manifest

      lset = manifest.xpath "//n:*[@client_id=\"#{client_id}\"]//n:login[@authentication=\"ssh-keys\"]", n: RSPEC3_NS
      if login = lset[0]
        hostname = login['hostname']
        port = login['port']
        if hostname && port
          return "#{hostname}:#{port}"
        end
      end
      nil
    end

    def released?
      self._status == 'released'
    end

    def expired?
      self.expires_at < Time.now
    end

    def provisioned?
      self.provisioned_at != nil
    end

    def progress(msg, timestamp = nil)
      self.progresses << "#{(timestamp || Time.now).utc.iso8601}: #{msg}"
    end

    def to_hash_long(h, objs, opts = {})
      raise DiscardedSliverException.new if released?
      super
      if (sp = h[:status]).is_a? OMF::SFA::Util::Promise
        # if status is a promise, it may update itself and change resources as well
        h[:resources] = rp = OMF::SFA::Util::Promise.new
        sp.on_success {|x| rp.resolve(self.resources)}
      end
      h
    end

    def to_hash_brief(opts = {})
      raise DiscardedSliverException.new if released?
      h = super

      self.manifest = self.manifest
      #h[:resource] = self.resources

      h
    end

    def initialize(opts)
      super
      self.status = :unknown
      self.created_at = Time.now
    end
  end # classs
end # module
