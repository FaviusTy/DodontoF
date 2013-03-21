# encoding:utf-8
$LOAD_PATH << File.dirname(__FILE__) + '/src_ruby'
$LOAD_PATH << File.dirname(__FILE__) + '/src_bcdice'

Encoding.default_external = 'utf-8'

require 'sinatra/base'
require 'rack-rewrite'
require 'msgpack'
require 'json'
require 'configure'
require 'msgpack_params_parser'
require 'server_commands'

class DodontoF < Sinatra::Base
  use Rack::MsgpackParamsParser
  use Rack::Rewrite do
    rewrite '/DodontoFServer.rb', '/'
  end

  set :public_folder => File.dirname(__FILE__)

  def action_params
    params[:params]
  end

  post '/' do
    p action_params
  end
end

if $0 === __FILE__
  DodontoF.run!
end