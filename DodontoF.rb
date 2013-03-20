# encoding:utf-8
$LOAD_PATH << File.dirname(__FILE__) + '/src_ruby'
$LOAD_PATH << File.dirname(__FILE__) + '/src_bcdice'

Encoding.default_external = 'utf-8'

require 'sinatra/base'
require 'rack-rewrite'
require 'msgpack_params_parser'
require 'msgpack'
require 'json'

class DodontoF < Sinatra::Base
  use Rack::MsgpackParamsParser
  use Rack::Rewrite do
    rewrite '/DodontoFServer.rb', '/'
  end
  set :public_folder => File.dirname(__FILE__)

  post '/' do
    'call'
  end
end

if $0 === __FILE__
  DodontoF.run!
end