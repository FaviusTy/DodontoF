# encoding: utf-8

require 'rack'
require 'msgpack'

module Rack

  class MsgpackParamsParser

    # Constants
    #
    CONTENT_TYPE = 'CONTENT_TYPE'.freeze
    POST_BODY = 'rack.input'.freeze
    FORM_INPUT = 'rack.request.form_input'.freeze
    FORM_HASH = 'rack.request.form_hash'.freeze

    # Supported Content-Types
    #
    APPLICATION_MSGPACK = 'application/x-msgpack'.freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      case env[CONTENT_TYPE]
        when APPLICATION_MSGPACK
          input_body = env[POST_BODY].read
          if input_body.length > 0
            unpacked_body = MessagePack.unpack(input_body)
            env.update(FORM_HASH => unpacked_body, FORM_INPUT => env[POST_BODY])
          end
        else
          # nothing to do
      end
      @app.call(env)
    end
  end

end

if __FILE__ == $0
  require 'sinatra/base'
  require 'test/unit'
  require 'rack/test'

  class TestServer < Sinatra::Base
    use Rack::MsgpackParamsParser

    post '/test' do
      params[:message]
    end
  end

  class RackTest < Test::Unit::TestCase
    include Rack::Test::Methods

    def app
      TestServer
    end

    def test_call
      data = {message: 'test_message' }
      post '/test', data.to_msgpack, 'CONTENT_TYPE' => 'application/x-msgpack'
      p last_response.body
    end
  end
end