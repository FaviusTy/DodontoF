# encoding:utf-8
$LOAD_PATH << File.dirname(__FILE__) + '/src_ruby'
$LOAD_PATH << File.dirname(__FILE__) + '/src_bcdice'

Encoding.default_external = 'utf-8'

require 'sinatra/base'
require 'logger'
require 'rack-rewrite'
require 'msgpack'
require 'json'
require 'diceBotInfos'
require 'configure'
require 'msgpack_params_parser'
require 'server_commands'

LOGGER = Logger.new('./log.txt')

class DodontoF < Sinatra::Base
  include ServerCommands

  TEST_RESPONSE = '「どどんとふ」の動作環境は正常に起動しています。'

  use Rack::MsgpackParamsParser
  use Rack::Rewrite do
    rewrite '/', '/index.html'
    rewrite '/DodontoFServer.rb', '/cmd'
  end

  set :public_folder => File.dirname(__FILE__)

  def action_params
    params[:params]
  end

  def execute_command
    current_command = COMMAND_REFERENCE[:"#{params[:cmd]}"] || ''
    LOGGER.debug "execute: #{current_command}"
    return TEST_RESPONSE if current_command.empty?

    #TODO 最終的にはmethod_missing内部でThrowするように修正した方が良い
    begin
      return send(current_command)
    end
  end

  post '/cmd' do
    LOGGER.info "request_params: #{params}"
    "#D@EM>##{execute_command.to_json}#<D@EM#"
  end

  post '/webif' do

  end
end

if $0 === __FILE__
  DodontoF.run!
end