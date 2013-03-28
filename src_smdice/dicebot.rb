#--*-coding:utf-8-*--

require 'core.rb'

class DiceBot

  SEND_STR_MAX = 99999 # 最大送信文字数(本来は500byte上限)

  def initialize
    @result = ''
    @secret = false
    @rands = nil #テスト以外ではnilで良い。ダイス目操作パラメータ
    @test = false
  end
  
  attr :secret

  def dummy_params
    @request_params = {
      :message => 'STG20',
      :gameType => 'TORG',
      :channel => '1',
      :state => 'state',
      :sendto => 'sendto',
      :color => '999999',
    }
    
    rollFromCgiParams
  end
  
  def rollFromCgiParams
    message = @request_params[:message]
    game_type = @request_params[:gameType] || 'diceBot'
    
    result = ''
    result << '##>customBot BEGIN<##'
    result << getDiceBotParamText('channel')
    result << getDiceBotParamText('name')
    result << getDiceBotParamText('state')
    result << getDiceBotParamText('sendto')
    result << getDiceBotParamText('color')
    result << message
    roll_result, _ = roll(message, game_type)
    result << roll_result
    result << '##>customBot END<##'
    
    result
  end
  
  def getDiceBotParamText(paramName)
    param = @request_params[paramName] || ''
    "#{param}\t"
  end
  
  def roll(message, game_type, dir = nil, prefix = '', need_result = false)
    roll_result, rand_results, game_type = executeDiceBot(message, game_type, dir, prefix, need_result)
    
    result = ''

    unless roll_result.empty?
      result << "\n#{game_type} #{roll_result}"
    end
    
    return result, rand_results
  end
  
  def setTest()
    @test = true
  end
  
  def setRandomValues(rands)
    @rands = rands
  end
  
  def executeDiceBot(message, game_type, dir = nil, prefix = '', need_result = false)

    bcdice = BCDiceMaker.new.newBcDice
    bcdice.setIrcClient(self)
    bcdice.setRandomValues(@rands)
    bcdice.isKeepSecretDice(false)
    bcdice.setTest(@test)
    bcdice.setCollectRandResult(need_result)
    bcdice.setDir(dir, prefix)
    
    bcdice.setGameByTitle(game_type)
    game_type = bcdice.getGameType
    bcdice.setMessage(message)
    
    channel = ''
    nick_e = ''
    bcdice.setChannel(channel)
    bcdice.recievePublicMessage(nick_e)
    
    roll_result = @result
    @result = ''
    
    randResults = bcdice.getRandResults
    
    return roll_result, randResults, game_type
  end
  
  def game_command_infos(dir, prefix)
    require 'TableFileData'
    
    table_file_data = TableFileData.new
    table_file_data.setDir(dir, prefix)
    table_file_data.getGameCommandInfos
  end
  
  def sendMessage(to, message)
    @result << message
  end
  
  def sendMessageToOnlySender(nick_e, message)
    @secret = true
    @result << message
  end
  
  def sendMessageToChannels(message)
    @result << message
  end
  
end


if $0 === __FILE__
  bot = DiceBot.new


  if ARGV.length > 0
    result, _ = bot.roll(ARGV[0], ARGV[1])
  else
    result = bot.dummy_params
  end
  
  print( result + "\n" )
end
