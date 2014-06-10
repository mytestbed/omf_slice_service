

REQUIRE_LOGIN = false

require 'rack/file'
class MyFile < Rack::File
  def call(env)
    c, h, b = super
    #h['Access-Control-Allow-Origin'] = '*'
    [c, h, b]
  end
end

require 'omf-sfa/resource/oresource'
OMF::SFA::Resource::OResource.href_resolver do |res, o|
  rtype = res.resource_type.to_sym
  unless [:slice, :user, :slice_member].include?(rtype)
    rtype = :resource
  end
  "http://#{Thread.current[:http_host]}/#{rtype}s/#{res.uuid}"
end

opts = OMF::Base::Thin::Runner.instance.options

# require 'omf-sfa/resource/oresource'
# OMF::SFA::Resource::OResource.href_resolver do |res, o|
  # unless @http_prefix ||=
    # @http_prefix = "http://#{Thread.current[:http_host]}"
  # end
  # case res.resource_type.to_sym
  # when :slice
    # "#@http_prefix/slices/#{res.uuid}"
  # when :slice_member
    # "#@http_prefix/slices/#{res.slice.uuid}/slice_members/#{res.uuid}"
  # else
    # "#@http_prefix/resources/#{res.uuid}"
  # end
# end
#
# opts = OMF::Base::Thin::Runner.instance.options

require 'rack/cors'
use Rack::Cors, debug: true do
  allow do
    origins '*'
    resource '*', :headers => :any, :methods => [:get, :post, :options]
  end
end

require 'omf-sfa/am/am-rest/session_authenticator'
use OMF::SFA::AM::Rest::SessionAuthenticator, #:expire_after => 10,
          :login_url => (REQUIRE_LOGIN ? '/login' : nil),
          :no_session => ['^/$', '^/login', '^/logout', '^/readme', '^/assets']

map '/' do
  p = lambda do |env|
    http_prefix = "http://#{env["HTTP_HOST"]}"
    toc = {}
    [:slices].each do |s|
      toc[s] = "#{http_prefix}/#{s}"
    end
    return [200 ,{'Content-Type' => 'application/json'}, JSON.pretty_generate(toc)]
  end
  run p
end

map '/slices' do
  require 'omf/slice_authority/slice_handler'
  run opts[:slice_handler] || OMF::SliceAuthority::SliceHandler.new(opts)
end

map '/users' do
  require 'omf/slice_authority/user_handler'
  run opts[:user_handler] || OMF::SliceAuthority::UserHandler.new(opts)
end

map '/slice_members' do
  require 'omf/slice_authority/slice_member_handler'
  run opts[:slice_member_handler] || OMF::SliceAuthority::SliceMemberHandler.new(opts)
end

if REQUIRE_LOGIN
  map '/login' do
    require 'omf-sfa/am/am-rest/login_handler'
    run OMF::SFA::AM::Rest::LoginHandler.new(opts[:am][:manager], opts)
  end
end

map "/readme" do
  require 'bluecloth'
  p = lambda do |env|
    s = File::read(File.dirname(__FILE__) + '/../../../README.md')
    frag = BlueCloth.new(s).to_html
    page = {
      service: '<h2><a href="/?_format=html">ROOT</a>/<a href="/readme">Readme</a></h2>',
      content: frag.gsub('http://localhost:8002', "http://#{env["HTTP_HOST"]}")
    }
    [200 ,{'Content-Type' => 'text/html'}, OMF::SFA::AM::Rest::RestHandler.render_html(page)]
  end
  run p
end

map '/assets' do
  run MyFile.new(File.dirname(__FILE__) + '/../../../share/assets')
end

map '/version' do
  l = lambda do |env|
    reply = {
      service: 'SliceService',
      version: OMF::SliceAuthority.version
    }
    [200 ,{'Content-Type' => 'application/json'}, JSON.pretty_generate(reply) + "\n"]
  end
  run l
end

map "/" do
  handler = Proc.new do |env|
    req = ::Rack::Request.new(env)
    case req.path_info
    when '/'
      http_prefix = "http://#{env["HTTP_HOST"]}"
      toc = ['README', :slices, :users].map do |s|
        "<li><a href='#{http_prefix}/#{s.to_s.downcase}?_format=html&_level=0'>#{s}</a></li>"
      end
      page = {
        service: 'Slice Authority',
        content: "<ul>#{toc.join("\n")}</ul>"
      }
      [200 ,{'Content-Type' => 'text/html'}, OMF::SFA::AM::Rest::RestHandler.render_html(page)]
    when '/favicon.ico'
      [301, {'Location' => '/assets/image/favicon.ico', "Content-Type" => ""}, ['Next window!']]
    else
      OMF::Base::Loggable.logger('rack').warn "Can't handle request '#{req.path_info}'"
      [401, {"Content-Type" => ""}, "Sorry!"]
    end
  end
  run handler
end


