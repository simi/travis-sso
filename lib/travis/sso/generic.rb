require 'travis/sso'

require 'rack/request'
require 'rack/file'
require 'rack/conditionalget'

require 'multi_json'
require 'open-uri'

module Travis
  module SSO
    class Generic
      CALLBACKS = [:pass, :set_user, :authenticated?]
      attr_reader :app, :endpoint, :files, :login_page

      def initialize(app, options = {})
        @app        = app
        @endpoint   = options[:endpoint]   || "https://api.travis-ci.org"
        static_dir  = options[:static_dir] || File.expand_path('../public',     __FILE__)
        template    = options[:template]   || File.expand_path('../login.html', __FILE__)
        static      = Rack::File.new(static_dir, 'public, must-revalidate')
        @files      = Rack::ConditionalGet.new(static)
        @login_page = File.read(template).gsub('%endpoint%', endpoint)

        CALLBACKS.each do |callback|
          define_singleton_method(callback, options[callback]) if options.include? callback
        end
      end

      def call(env)
        request = Rack::Request.new(env)
        static(request) || login(request) || handshake(request) || allow(request)
      end

      protected

        def pass(request)
          raise NotImplementedError, 'subclass responsibility'
        end

        def set_user(request, user)
          raise NotImplementedError, 'subclass responsibility'
        end

        def authenticated?(request)
          raise NotImplementedError, 'subclass responsibility'
        end

      private

        def static(request)
          return unless request.path_info =~ %r[^(/?__travis__)(/.*)$]
          env = request.env.merge('SCRIPT_NAME' => request.script_name + $1, 'PATH_INFO' => $2)
          files.call(env)
        end

        def allow(request)
          app.call(request.env)
        end

        def login(request)
          return unless request.post? and token = request.params['sso_token']
          data = MultiJson.decode(open("#{endpoint}/users?access_token=#{token}").read)
          user = data['user'].merge('token' =>  token)
          set_user(request, user)
          pass(request)
        rescue OpenURI::HTTPError => error
          response(error.io.read, Integer(error.message[/40\d/] || 403))
        rescue EOFError
        end

        def handshake(request)
          return if authenticated?(request)
          if request.head? or request.get?
            prefix = File.join(request.script_name, '__travis__')
            origin = "#{request.scheme}://#{request.host_with_port}"
            response login_page.gsub('%public%', prefix).gsub('%origin%', origin)
          else
            response(405, "must be <a href='#{request.url}'>GET</a> request", 'Allow' => 'GET, HEAD')
          end
        end

        def response(*args)
          body    = args.grep(String)
          status  = args.grep(Integer).first       || 200
          headers = args.grep(Hash).inject(:merge) || {}
          headers['Content-Type']   ||= 'text/html'
          headers['Content-Length'] ||= body.join.bytesize.to_s
          [status, headers, body]
        end
    end
  end
end
