#!/usr/local/bin/ruby -Ku
# encoding: utf-8
$LOAD_PATH << File.dirname(__FILE__) + "/src_ruby"
$LOAD_PATH << File.dirname(__FILE__) + "/src_bcdice"

#CGI通信の主幹クラス用ファイル
#ファイルアップロード系以外は全てこのファイルへ通知が送られます。
#クライアント通知されたJsonデータからセーブデータ(.jsonテキスト)を読み出し・書き出しするのが主な作業。
#変更可能な設定は config.rb にまとめているため、環境設定のためにこのファイルを変更する必要は基本的には無いです。


if RUBY_VERSION >= '1.9.0'
  Encoding.default_external = 'utf-8'
else
  require 'jcode'
end

require 'kconv'
require 'cgi'
require 'stringio'
require 'logger'
require 'uri'
require 'fileutils'
require 'json/jsonParser'

if $isFirstCgi
  require 'cgiPatch_forFirstCgi'
end

require "config.rb"


if $isMessagePackInstalled
  # gem install msgpack バージョン
  require 'rubygems'
  require 'msgpack'
else
  # Pure Ruby MessagePackバージョン
  require 'msgpack/msgpackPure'
end


require "loggingFunction.rb"
require "FileLock.rb"
# require "FileLock2.rb"
require "saveDirInfo.rb"

#TODO:FIXME グローバル変数の名称変更は影響範囲を鑑みて一旦後回し
$saveFileNames = File.join($saveDataTempDir, 'saveFileNames.json')
$imageUrlText = File.join($imageUploadDir, 'imageUrl.txt')

$chatMessageDataLogAll = 'chatLongLines.txt'

$loginUserInfo = 'login.json'
$playRoomInfo = 'playRoomInfo.json'
$playRoomInfoTypeName = 'playRoomInfo'

$saveFiles = {
    'chatMessageDataLog' => 'chat.json',
    'map' => 'map.json',
    'characters' => 'characters.json',
    'time' => 'time.json',
    'effects' => 'effects.json',
    $playRoomInfoTypeName => $playRoomInfo,
}

$recordKey = 'record'
$record = 'record.json'


class DodontoFServer

  def initialize(savedir_info, request_params)
    @request_params = request_params
    @savedir_info = savedir_info

    room_index_key = "room"
    init_savefiles(request_data(room_index_key))

    @is_add_marker = false
    @jsonp_callback = nil
    @is_web_interface = false
    @is_json_result = true
    @is_record_empty = false

    @dicebot_table_prefix = 'diceBotTable_'
    @full_backup_base_name = "DodontoFFullBackup"
    @scenario_file_ext = '.tar.gz'
    @card = nil
  end

  def init_savefiles(room_index)
    @savedir_info.init(room_index, $saveDataMaxCount, $SAVE_DATA_DIR)

    @savefiles = {}
    $saveFiles.each do |saveDataKeyName, saveFileName|
      logging(saveDataKeyName, "saveDataKeyName")
      logging(saveFileName, "saveFileName")
      @savefiles[saveDataKeyName] = @savedir_info.getTrueSaveFileName(saveFileName)
    end

  end


  def request_data(key)
    logging(key, "getRequestData key")

    value = @request_params[key]
    logging(@request_params, "@cgiParams")
    # logging(value, "getRequestData value")

    if value.nil?
      if @is_web_interface
        @cgi ||= CGI.new
        value = @cgi.request_params[key].first
      end
    end


    logging(value, "getRequestData result")
    value
  end


  attr :is_add_marker
  attr :jsonp_callback
  attr :is_json_result

  def cards_info
    require "card.rb"

    return @card unless (@card.nil?)

    @card = Card.new()
  end

  def savefile_lock_readonly(file_name)
    savefile_lock(file_name, true)
  end

  def real_savefile_lock_readonly(file_name)
    real_savefile_lock(file_name, true)
  end

  def self.lockfile_name(savefile_name)
    default_name = (savefile_name + ".lock")

    if $SAVE_DATA_LOCK_FILE_DIR.nil?
      return default_name
    end

    if savefile_name.index($SAVE_DATA_DIR) != 0
      return default_name
    end

    subdir_name = savefile_name[$SAVE_DATA_DIR.size .. -1]

    File.join($SAVE_DATA_LOCK_FILE_DIR, subdir_name) + ".lock"
  end

  #override
  def savefile_lock(file_name, readonly = false)
    real_savefile_lock(file_name, readonly)
  end

  def real_savefile_lock(file_name, readonly = false)
    begin
      lockfile_name = self.class.lockfile_name(file_name)
      return FileLock.new(lockfile_name)
        #return FileLock2.new(saveFileName + ".lock", isReadOnly)
    rescue => e
      loggingForce(@savedir_info.inspect, "when getSaveFileLock error : @saveDirInfo.inspect")
      raise
    end
  end

  #override
  def exist?(file_name)
    File.exist?(file_name)
  end

  #override
  def exist_dir?(dir_name)
    File.exist?(dir_name)
  end

  #override
  def readlines(file_name)
    lines = File.readlines(file_name)
  end

  def load_long_chatlog(type_name, savefile_name)
    savefile_name = @savedir_info.getTrueSaveFileName($chatMessageDataLogAll)
    lockfile = savefile_lock_readonly(savefile_name)

    lines = []
    lockfile.lock do
      if exist?(savefile_name)
        lines = readlines(savefile_name)
      end

      @last_update_times[type_name] = getSaveFileTimeStampMillSecond(savefile_name)
    end

    if lines.empty?
      return {}
    end

    log_data = lines.collect { |line| parse_json(line.chomp) }

    {"chatMessageDataLog" => log_data}
  end

  def load_savefile(type_name, file_name)
    logging("loadSaveFile begin")

    save_data = nil

    begin
      if long_chatlog?(type_name)
        save_data = load_long_chatlog(type_name, file_name)
      elsif $isUseRecord and character_file?(type_name)
        logging("isCharacterType")
        save_data = load_character(type_name, file_name)
      else
        save_data = load_default_savefile(type_name, file_name)
      end
    rescue => e
      loggingException(e)
      raise e
    end

    logging(save_data.inspect, file_name)

    logging("loadSaveFile end")

    save_data
  end

  def long_chatlog?(type_name)
    ($IS_SAVE_LONG_CHAT_LOG and chat_file?(type_name) and @last_update_times[type_name] == 0)
  end

  def chat_file?(type_name)
    (type_name == 'chatMessageDataLog')
  end


  def character_file?(type_name)
    (type_name == "characters")
  end

  def load_character(type_name, file_name)
    logging(@last_update_times, "loadSaveFileForCharacter begin @lastUpdateTimes")

    character_update_time = getSaveFileTimeStampMillSecond(file_name)

    #後の操作順序に依存せずRecord情報が取得できるよう、ここでRecordをキャッシュしておく。
    #こうしないとRecordを取得する順序でセーブデータと整合性が崩れる場合があるため
    record_caching

    save_data = record_by_cache()
    logging(save_data, "getRecordSaveDataFromCash saveData")

    if save_data.nil?
      save_data = load_default_savefile(type_name, file_name)
    else
      @last_update_times[type_name] = character_update_time
    end

    @last_update_times['recordIndex'] = last_record_index_by_cache

    logging(@last_update_times, "loadSaveFileForCharacter End @lastUpdateTimes")
    logging(save_data, "loadSaveFileForCharacter End saveData")

    save_data
  end

  def record_by_cache()
    record_index = @last_update_times['recordIndex']

    logging("getRecordSaveDataFromCash begin")
    logging(record_index, "recordIndex")
    logging(@record, "@record")

    return nil if (record_index.nil?)
    return nil if (record_index == 0)
    return nil if (@record.nil?)
    return nil if (@record.empty?)

    current_sender = command_sender
    found = false

    record_data = []

    @record.each do |params|
      index, command, list, sender = params

      logging(index, "@record.each index")

      if index == record_index
        found = true
        next
      end

      next unless (found)

      if need_yourself_record?(sender, current_sender, command)
        record_data << params
      end

    end

    save_data = nil
    if found
      logging(record_data, "recordData")
      save_data = {'record' => record_data}
    end

    save_data
  end

  def need_yourself_record?(sender, current_sender, command)

    #自分のコマンドでも…Record送信して欲しいときはあるよねっ！
    return true if (@isGetOwnRecord)

    #自分が送ったコマンドであっても結果を取得しないといけないコマンド名はここに列挙
    #キャラクター追加なんかのコマンドは字自分のコマンドでも送信しないとダメなんだよね
    need_commands = ['addCharacter']
    return true if (need_commands.include?(command))

    #でも基本的には、自分が送ったコマンドは受け取りたくないんですよ
    return false if (current_sender == sender)

    true
  end

  def last_record_index_by_cache
    record_index = 0

    record = record_caching

    last = record.last
    unless last.nil?
      record_index = last[0]
    end

    logging(record_index, "getLastRecordIndexFromCash recordIndex")

    record_index
  end

  def record_caching
    unless @record.nil?
      return @record
    end

    real_savefile_name = @savedir_info.getTrueSaveFileName($record)
    save_data = load_default_savefile($recordKey, real_savefile_name)
    @record = record_by_save_data(save_data)
  end

  def load_default_savefile(type_name, file_name)
    lockfile = savefile_lock_readonly(file_name)

    text_data = ""
    lockfile.lock do
      @last_update_times[type_name] = getSaveFileTimeStampMillSecond(file_name)
      text_data = extract_safed_file_text(file_name)
    end

    parse_json(text_data)
  end

  def save_data(savefile_name)
    lockfile = savefile_lock(savefile_name, true)

    text_data = nil
    lockfile.lock do
      text_data = extract_safed_file_text(savefile_name)
    end

    save_data = parse_json(text_data)
    yield(save_data)
  end

  def change_save_data(savefile_name)

    character_data = (@savefiles['characters'] == savefile_name)

    lockfile = savefile_lock(savefile_name)

    lockfile.lock do
      text_data = extract_safed_file_text(savefile_name)
      save_data = parse_json(text_data)

      if character_data
        save_character_history(save_data) do
          yield(save_data)
        end
      else
        yield(save_data)
      end

      text_data = build_json(save_data)
      create_file(savefile_name, text_data)
    end
  end

  def save_character_history(save_data)
    logging("saveCharacterHistory begin")

    before = deep_copy(save_data['characters'])
    logging(before, "saveCharacterHistory BEFORE")
    yield
    after = save_data['characters']
    logging(after, "saveCharacterHistory AFTER")

    added = not_exist_characters(after, before)
    removed = not_exist_characters(before, after)
    changed = changed_characters(before, after)

    removed_ids = removed.collect { |i| i['imgId'] }

    real_savefile_name = @savedir_info.getTrueSaveFileName($record)
    change_save_data(real_savefile_name) do |_save_data|
      if @is_record_empty
        clear_record(_save_data)
      else
        write_record(_save_data, 'removeCharacter', removed_ids)
        write_record(_save_data, 'addCharacter', added)
        write_record(_save_data, 'changeCharacter', changed)
      end
    end
    logging("saveCharacterHistory end")
  end

  def deep_copy(obj)
    Marshal.load(Marshal.dump(obj))
  end

  def not_exist_characters(first, second)
    result = []

    first.each do |a|
      same = second.find { |b| a['imgId'] == b['imgId'] }
      if same.nil?
        result << a
      end
    end

    result
  end

  def changed_characters(before, after)
    result = []

    after.each do |a|
      logging(a, "getChangedCharacters find a")

      b = before.find { |i| a['imgId'] == i['imgId'] }
      next if (b.nil?)

      logging(b, "getChangedCharacters find b")

      next if (a == b)

      result << a
    end

    logging(result, "getChangedCharacters result")

    result
  end


  def write_record(save_data, key, list)
    logging("writeRecord begin")
    logging(list, "list")

    if list.nil? or list.empty?
      logging("list is empty.")
      return nil
    end

    record = record_by_save_data(save_data)
    logging(record, "before record")

    while record.length >= $recordMaxCount
      record.shift
      break if (record.length == 0)
    end

    record_index = 1

    last = record.last
    unless last.nil?
      record_index = last[0].to_i + 1
    end

    sender = command_sender

    record << [record_index, key, list, sender]
    logging(record, "after record")

    logging("writeRecord end")
  end

  def clear_record(save_data)
    logging("clearRecord Begin")
    record = record_by_save_data(save_data)
    record.clear
    logging("clearRecord End")
  end

  def command_sender
    if @command_sender.nil?
      @command_sender = request_data('own')
    end

    logging(@command_sender, "@commandSender")

    @command_sender
  end

  def set_no_body_sender
    @command_sender = "-\t-"
  end

  def set_record_empty
    @is_record_empty = true
  end

  def record_by_save_data(save_data)
    save_data ||= {}
    save_data['record'] ||= []
    record = save_data['record']
  end

  def create_savefile(file_name, text)
    logging(file_name, 'createSaveFile saveFileName')
    exist_files = nil

    logging($saveFileNames, "$saveFileNames")
    change_save_data($saveFileNames) do |save_data|
      exist_files = save_data["fileNames"]
      exist_files ||= []
      logging(exist_files, 'pre existFiles')

      unless exist_files.include?(file_name)
        exist_files << file_name
      end

      create_file(file_name, text)

      save_data["fileNames"] = exist_files
    end

    logging(exist_files, 'createSaveFile existFiles')
  end

  #override
  def create_file(file_name, text)
    begin
      File.open(file_name, "w+") do |file|
        file.write(text.toutf8)
      end
    rescue => e
      loggingException(e)
      raise e
    end
  end

  def build_json(source_data)
    self.class.build_json(source_data)
  end

  def self.build_json(source_data)
    return JsonBuilder.new.build(source_data)
  end

  def build_msgpack(data)
    self.class.build_msgpack(data)
  end

  def self.build_msgpack(data)
    if $isMessagePackInstalled
      MessagePack.pack(data)
    else
      MessagePackPure::Packer.new(StringIO.new).write(data).string
    end
  end

  def parse_json(text)
    self.class.parse_json(text)
  end

  def self.parse_json(text)
    parsed_data = nil
    begin
      logging(text, "getJsonDataFromText start")
      begin
        parsed_data = JsonParser.new.parse(text)
        logging("getJsonDataFromText 1 end")
      rescue => e
        text = CGI.unescape(text)
        parsed_data = JsonParser.new.parse(text)
        logging("getJsonDataFromText 2 end")
      end
    rescue => e
      # loggingException(e)
      parsed_data = {}
    end

    return parsed_data
  end

  def parse_msgpack(data)
    self.class.parse_msgpack(data)
  end

  def self.parse_msgpack(data)
    logging("getMessagePackFromData Begin")

  parsed_data = {}

    if data.nil?
      logging("data is nil")
      return parsed_data
    end

    begin
      if $isMessagePackInstalled
        parsed_data = MessagePack.unpack(data)
      else
        parsed_data = MessagePackPure::Unpacker.new(StringIO.new(data, "r")).read
      end
    rescue => e
      loggingForce("getMessagePackFromData rescue")
      loggingException(e)
    rescue Exception => e
      loggingForce("getMessagePackFromData Exception rescue")
      loggingException(e)
    end

    logging(parsed_data, "messagePack")

    if is_webif_msgpack(parsed_data)
      logging(data, "data is webif.")
      parsed_data = reform_webif_data(data)
    end

    logging(parsed_data, "getMessagePackFromData End messagePack")

    return parsed_data
  end

  def self.is_webif_msgpack(parsed_data)
    logging(parsed_data, "isWebif messagePack")

    unless parsed_data.kind_of?(Hash)
      logging("messagePack is NOT Hash")
      return true
    end

    return false
  end

  def self.reform_webif_data(data)
    params = CGI.parse(data)
    logging(params, "params")

    reformed_data = {}
    params.each do |key, value|
      reformed_data[key] = value.first
    end

    return reformed_data
  end

  #override
  def extract_safed_file_text(savefile_name)
    empty = "{}"

    return empty unless (exist?(savefile_name))

    text = ''
    open(savefile_name, 'r') do |file|
      text = file.read
    end

    return empty if (text.empty?)

    text
  end

  def analyze_command
    current_command = request_data('cmd')

    logging(current_command, "commandName")

    if current_command.nil? or current_command.empty?
      return response_for_none_command
    end

    has_return = "hasReturn"
    no_return = "hasNoReturn"

    commands = [
        ['refresh', has_return],

        ['getGraveyardCharacterData', has_return],
        ['resurrectCharacter', has_return],
        ['clearGraveyard', has_return],
        ['getLoginInfo', has_return],
        ['getPlayRoomStates', has_return],
        ['getPlayRoomStatesByCount', has_return],
        ['deleteImage', has_return],
        ['uploadImageUrl', has_return],
        ['save', has_return],
        ['saveMap', has_return],
        ['saveScenario', has_return],
        ['load', has_return],
        ['loadScenario', has_return],
        ['getDiceBotInfos', has_return],
        ['getBotTableInfos', has_return],
        ['addBotTable', has_return],
        ['changeBotTable', has_return],
        ['removeBotTable', has_return],
        ['requestReplayDataList', has_return],
        ['uploadReplayData', has_return],
        ['removeReplayData', has_return],
        ['checkRoomStatus', has_return],
        ['loginPassword', has_return],
        ['uploadFile', has_return],
        ['uploadImageData', has_return],
        ['createPlayRoom', has_return],
        ['changePlayRoom', has_return],
        ['removePlayRoom', has_return],
        ['removeOldPlayRoom', has_return],
        ['getImageTagsAndImageList', has_return],
        ['addCharacter', has_return],
        ['getWaitingRoomInfo', has_return],
        ['exitWaitingRoomCharacter', has_return],
        ['enterWaitingRoomCharacter', has_return],
        ['sendDiceBotChatMessage', has_return],
        ['deleteChatLog', has_return],
        ['sendChatMessageAll', has_return],
        ['undoDrawOnMap', has_return],

        ['logout', no_return],
        ['changeCharacter', no_return],
        ['removeCharacter', no_return],

        # Card Command Get
        ['getMountCardInfos', has_return],
        ['getTrushMountCardInfos', has_return],

        # Card Command Set
        ['drawTargetCard', has_return],
        ['drawTargetTrushCard', has_return],
        ['drawCard', has_return],
        ['addCard', no_return],
        ['addCardZone', no_return],
        ['initCards', has_return],
        ['returnCard', no_return],
        ['shuffleCards', no_return],
        ['shuffleForNextRandomDungeon', no_return],
        ['dumpTrushCards', no_return],

        ['clearCharacterByType', no_return],
        ['moveCharacter', no_return],
        ['changeMap', no_return],
        ['drawOnMap', no_return],
        ['clearDrawOnMap', no_return],
        ['sendChatMessage', no_return],
        ['changeRoundTime', no_return],
        ['addEffect', no_return],
        ['changeEffect', no_return],
        ['removeEffect', no_return],
        ['changeImageTags', no_return],
    ]

    commands.each do |command, type|
      next unless (command == current_command)
      logging(type, "commandType")

      case type
        when has_return
          return eval(command) #TODO:WHAT? 以前はsendだった気がするが、なぜevalなのか
        when no_return
          eval(command)
          return nil
        else
      end
    end

    throw Exception.new("\"" + current_command.untaint + "\" is invalid command")

  end

  def response_for_none_command
    logging("getResponseTextWhenNoCommandName Begin")

    response = analyze_webif_command

    if response.nil?
      response = test_response
    end

    response
  end

  def analyze_webif_command
    result = {'result' => 'NG'}

    begin
      result = routing_webif_command
      logging("analyzeWebInterfaceCatched end result", result)
      set_jsonp_callback
    rescue => e
      result['result'] = e.to_s
    end

    result
  end

  def routing_webif_command
    logging("analyzeWebInterfaceCatched begin")

    @is_web_interface = true
    @is_json_result = true

    current_command = request_data('webif')
    logging(current_command, 'commandName')

    if invalid_param?(current_command)
      return nil
    end

    marker = request_data('marker')
    if invalid_param?(marker)
      @is_add_marker = false
    end

    logging(current_command, "commandName")

    case current_command
      when 'getBusyInfo'
        return getBusyInfo
      when 'getServerInfo'
        return getWebIfServerInfo
      when 'getRoomList'
        logging("getRoomList passed")
        return getWebIfRoomList
      else

    end

    login_on_web_interface

    case current_command
      when 'chat'
        return getWebIfChatText
      when 'talk'
        return sendWebIfChatText
      when 'addCharacter'
        return sendWebIfAddCharacter
      when 'changeCharacter'
        return sendWebIfChangeCharacter
      when 'addMemo'
        return sendWebIfAddMemo
      when 'getRoomInfo'
        return getWebIfRoomInfo
      when 'setRoomInfo'
        return setWebIfRoomInfo
      when 'getChatColor'
        return getChatColor
      when 'refresh'
        return getWebIfRefresh
      else

    end

    {'result' => "command [#{current_command}] is NOT found"}
  end


  def login_on_web_interface
    text_room_index = request_data('room')
    if invalid_param?(text_room_index)
      raise "プレイルーム番号(room)を指定してください"
    end

    unless /^\d+$/ === text_room_index
      raise "プレイルーム番号(room)には半角数字のみを指定してください"
    end

    room_index = text_room_index.to_i

    password = request_data('password')
    visitor_mode = true

    checked_result = checkLoginPassword(room_index, password, visitor_mode)
    if checked_result['resultText'] != "OK"
      result['result'] = result['resultText']
      return result
    end

    init_savefiles(room_index)
  end


  def invalid_param?(param)
    (param.nil? or param.empty?)
  end

  def set_jsonp_callback
    callback = request_data('callback')

    logging('callBack', callback)
    if invalid_param?(callback)
      return
    end

    @jsonp_callback = callback
  end


  def test_response
    "「どどんとふ」の動作環境は正常に起動しています。"
  end


  def current_save_data()
    @savefiles.each do |type_name, file_name|
      logging(type_name, "saveFileTypeName")
      logging(file_name, "saveFileName")

      target_last_update_time = @last_update_times[type_name]
      next if (target_last_update_time == nil)

      logging(target_last_update_time, "targetLastUpdateTime")

      if isSaveFileChanged(target_last_update_time, file_name)
        logging(file_name, "saveFile is changed")
        save_data = load_savefile(type_name, file_name)
        yield(save_data, type_name)
      end
    end
  end


  def getWebIfChatText
    logging("getWebIfChatText begin")

    time= getWebIfRequestNumber('time', -1)
    unless time == -1
      save_data = chat_text_by_time(time)
    else
      seconds = request_data('sec')
      save_data = chat_text_by_second(seconds)
    end

    save_data['result'] = 'OK'

    save_data
  end


  def chat_text_by_time(time)
    logging(time, 'getWebIfChatTextFromTime time')

    save_data = {}
    @last_update_times = {'chatMessageDataLog' => time}
    refreshLoop(save_data)

    deleteOldChatTextForWebIf(time, save_data)

    logging(save_data, 'getWebIfChatTextFromTime saveData')

    save_data
  end


  def chat_text_by_second(seconds)
    logging(seconds, 'getWebIfChatTextFromSecond seconds')

    time = getTimeForGetWebIfChatText(seconds)
    logging(seconds, "seconds")
    logging(time, "time")

    save_data = {}
    @last_update_times = {'chatMessageDataLog' => time}
    current_save_data() do |targetSaveData, saveFileTypeName|
      save_data.merge!(targetSaveData)
    end

    deleteOldChatTextForWebIf(time, save_data)

    logging("getCurrentSaveData end saveData", save_data)

    save_data
  end

  def deleteOldChatTextForWebIf(time, saveData)
    logging(time, 'deleteOldChatTextForWebIf time')

    return if (time.nil?)

    chats = saveData['chatMessageDataLog']
    return if (chats.nil?)

    chats.delete_if do |writtenTime, data|
      ((writtenTime < time) or (not data['sendto'].nil?))
    end

    logging('deleteOldChatTextForWebIf End')
  end


  def getTimeForGetWebIfChatText(seconds)
    case seconds
      when "all"
        return 0
      when nil
        return Time.now.to_i - $oldMessageTimeout
      else
    end

    Time.now.to_i - seconds.to_i
  end


  def getChatColor()
    name = getWebIfRequestText('name')
    logging(name, "name")
    if invalid_param?(name)
      raise "対象ユーザー名(name)を指定してください"
    end

    color = getChatColorFromChatSaveData(name)
    # color ||= getTalkDefaultColor
    if color.nil?
      raise "指定ユーザー名の発言が見つかりません"
    end

    result = {}
    result['result'] = 'OK'
    result['color'] = color

    result
  end

  def getChatColorFromChatSaveData(name)
    seconds = 'all'
    saveData = chat_text_by_second(seconds)

    chats = saveData['chatMessageDataLog']
    chats.reverse_each do |time, data|
      senderName = data['senderName'].split(/\t/).first
      if name == senderName
        return data['color']
      end
    end

    nil
  end

  def getTalkDefaultColor
    "000000"
  end

  def getBusyInfo()
    jsonData = {
        "loginCount" => File.readlines($loginCountFile).join.to_i,
        "maxLoginCount" => $aboutMaxLoginCount,
        "version" => $version,
        "result" => 'OK',
    }

    jsonData
  end

  def getWebIfServerInfo()
    jsonData = {
        "maxRoom" => ($saveDataMaxCount - 1),
        'isNeedCreatePassword' => (not $createPlayRoomPassword.empty?),
        'result' => 'OK',
    }

    if getWebIfRequestBoolean("card", false)
      cardInfos = cards_info.collectCardTypeAndTypeName()
      jsonData["cardInfos"] = cardInfos
    end

    if getWebIfRequestBoolean("dice", false)
      require 'diceBotInfos'
      diceBotInfos = DiceBotInfos.new.getInfos
      jsonData['diceBotInfos'] = getDiceBotInfos()
    end

    jsonData
  end

  def getWebIfRoomList()
    logging("getWebIfRoomList Begin")
    minRoom = getWebIfRequestInt('minRoom', 0)
    maxRoom = getWebIfRequestInt('maxRoom', ($saveDataMaxCount - 1))

    playRoomStates = getPlayRoomStatesLocal(minRoom, maxRoom)

    jsonData = {
        "playRoomStates" => playRoomStates,
        "result" => 'OK',
    }

    logging("getWebIfRoomList End")
    jsonData
  end

  def sendWebIfChatText
    logging("sendWebIfChatText begin")
    saveData = {}

    name = getWebIfRequestText('name')
    logging(name, "name")

    message = getWebIfRequestText('message')
    message.gsub!(/\r\n/, "\r")
    logging(message, "message")

    color = getWebIfRequestText('color', getTalkDefaultColor)
    logging(color, "color")

    channel = getWebIfRequestInt('channel')
    logging(channel, "channel")

    gameType = getWebIfRequestText('bot')
    logging(gameType, 'gameType')

    rollResult, isSecret, randResults = rollDice(message, gameType, false)

    message = message + rollResult
    logging(message, "diceRolled message")

    chatData = {
        "senderName" => name,
        "message" => message,
        "color" => color,
        "uniqueId" => '0',
        "channel" => channel,
    }
    logging("sendWebIfChatText chatData", chatData)

    sendChatMessageByChatData(chatData)

    result = {}
    result['result'] = 'OK'
    result
  end

  def getWebIfRequestText(key, default = '')
    text = request_data(key)

    if text.nil? or text.empty?
      text = default
    end

    text
  end

  def getWebIfRequestInt(key, default = 0)
    text = getWebIfRequestText(key, default.to_s)
    text.to_i
  end

  def getWebIfRequestNumber(key, default = 0)
    text = getWebIfRequestText(key, default.to_s)
    text.to_f
  end

  def getWebIfRequestBoolean(key, default = false)
    text = getWebIfRequestText(key)
    if text.empty?
      return default
    end

    (text == "true")
  end

  def getWebIfRequestArray(key, empty = [], separator = ',')
    text = getWebIfRequestText(key, nil)

    if text.nil?
      return empty
    end

    text.split(separator)
  end

  def getWebIfRequestHash(key, default = {}, separator1 = ':', separator2 = ',')
    logging("getWebIfRequestHash begin")
    logging(key, "key")
    logging(separator1, "separator1")
    logging(separator2, "separator2")

    array = getWebIfRequestArray(key, [], separator2)
    logging(array, "array")

    if array.empty?
      return default
    end

    hash = {}
    array.each do |value|
      logging(value, "array value")
      key, value = value.split(separator1)
      hash[key] = value
    end

    logging(hash, "getWebIfRequestHash result")

    hash
  end

  def sendWebIfAddMemo
    logging('sendWebIfAddMemo begin')

    result = {}
    result['result'] = 'OK'

    jsonData = {
        "message" => getWebIfRequestText('message', ''),
        "x" => 0,
        "y" => 0,
        "height" => 1,
        "width" => 1,
        "rotation" => 0,
        "isPaint" => true,
        "color" => 16777215,
        "draggable" => true,
        "type" => "Memo",
        "imgId" => createCharacterImgId(),
    }

    logging(jsonData, 'sendWebIfAddMemo jsonData')
    addResult = addCharacterData([jsonData])

    result
  end


  def sendWebIfAddCharacter
    logging("sendWebIfAddCharacter begin")

    result = {}
    result['result'] = 'OK'

    jsonData = {
        "name" => getWebIfRequestText('name'),
        "size" => getWebIfRequestInt('size', 1),
        "x" => getWebIfRequestInt('x', 0),
        "y" => getWebIfRequestInt('y', 0),
        "initiative" => getWebIfRequestNumber('initiative', 0),
        "counters" => getWebIfRequestHash('counters'),
        "info" => getWebIfRequestText('info'),
        "imageName" => getWebIfImageName('image', ".\/image\/defaultImageSet\/pawn\/pawnBlack.png"),
        "rotation" => getWebIfRequestInt('rotation', 0),
        "statusAlias" => getWebIfRequestHash('statusAlias'),
        "dogTag" => getWebIfRequestText('dogTag', ""),
        "draggable" => getWebIfRequestBoolean("draggable", true),
        "isHide" => getWebIfRequestBoolean("isHide", false),
        "type" => "characterData",
        "imgId" => createCharacterImgId(),
    }

    logging(jsonData, 'sendWebIfAddCharacter jsonData')


    if jsonData['name'].empty?
      result['result'] = "キャラクターの追加に失敗しました。キャラクター名が設定されていません"
      return result
    end


    addResult = addCharacterData([jsonData])
    addFailedCharacterNames = addResult["addFailedCharacterNames"]
    logging(addFailedCharacterNames, 'addFailedCharacterNames')

    if (addFailedCharacterNames.length > 0)
      result['result'] = "キャラクターの追加に失敗しました。同じ名前のキャラクターがすでに存在しないか確認してください。\"#{addFailedCharacterNames.join(' ')}\""
    end

    result
  end

  def getWebIfImageName(key, default)
    logging("getWebIfImageName begin")
    logging(key, "key")
    logging(default, "default")

    image = getWebIfRequestText(key, default)
    logging(image, "image")

    if image != default
      image.gsub!('(local)', $imageUploadDir)
      image.gsub!('__LOCAL__', $imageUploadDir)
    end

    logging(image, "getWebIfImageName result")

    image
  end


  def sendWebIfChangeCharacter
    logging("sendWebIfChangeCharacter begin")

    result = {}
    result['result'] = 'OK'

    begin
      sendWebIfChangeCharacterChatched
    rescue => e
      loggingException(e)
      result['result'] = e.to_s
    end

    result
  end

  def sendWebIfChangeCharacterChatched
    logging("sendWebIfChangeCharacterChatched begin")

    targetName = getWebIfRequestText('targetName')
    logging(targetName, "targetName")

    if targetName.empty?
      raise '変更するキャラクターの名前(\'target\'パラメータ）が正しく指定されていません'
    end


    change_save_data(@savefiles['characters']) do |saveData|

      characterData = getCharacterDataByName(saveData, targetName)
      logging(characterData, "characterData")

      if characterData.nil?
        raise "「#{targetName}」という名前のキャラクターは存在しません"
      end

      name = getWebIfRequestAny(:getWebIfRequestText, 'name', characterData)
      logging(name, "name")

      if characterData['name'] != name
        failedName = isAlreadyExistCharacterInRoom?(saveData, {'name' => name})
        if failedName
          raise "「#{name}」という名前のキャラクターはすでに存在しています"
        end
      end

      characterData['name'] = name
      characterData['size'] = getWebIfRequestAny(:getWebIfRequestInt, 'size', characterData)
      characterData['x'] = getWebIfRequestAny(:getWebIfRequestNumber, 'x', characterData)
      characterData['y'] = getWebIfRequestAny(:getWebIfRequestNumber, 'y', characterData)
      characterData['initiative'] = getWebIfRequestAny(:getWebIfRequestNumber, 'initiative', characterData)
      characterData['counters'] = getWebIfRequestAny(:getWebIfRequestHash, 'counters', characterData)
      characterData['info'] = getWebIfRequestAny(:getWebIfRequestText, 'info', characterData)
      characterData['imageName'] = getWebIfRequestAny(:getWebIfImageName, 'image', characterData, 'imageName')
      characterData['rotation'] = getWebIfRequestAny(:getWebIfRequestInt, 'rotation', characterData)
      characterData['statusAlias'] = getWebIfRequestAny(:getWebIfRequestHash, 'statusAlias', characterData)
      characterData['dogTag'] = getWebIfRequestAny(:getWebIfRequestText, 'dogTag', characterData)
      characterData['draggable'] = getWebIfRequestAny(:getWebIfRequestBoolean, 'draggable', characterData)
      characterData['isHide'] = getWebIfRequestAny(:getWebIfRequestBoolean, 'isHide', characterData)
      # 'type' => 'characterData',
      # 'imgId' =>  createCharacterImgId(),

    end

  end

  def getCharacterDataByName(saveData, targetName)
    characters = getCharactersFromSaveData(saveData)

    characterData = characters.find do |i|
      (i['name'] == targetName)
    end

    characterData
  end


  def getWebIfRoomInfo
    logging("getWebIfRoomInfo begin")

    result = {}
    result['result'] = 'OK'

    save_data(@savefiles['time']) do |saveData|
      logging(saveData, "saveData")
      roundTimeData = getHashValue(saveData, 'roundTimeData', {})
      result['counter'] = getHashValue(roundTimeData, "counterNames", [])
    end

    roomInfo = getRoomInfoForWebIf
    result.merge!(roomInfo)

    logging(result, "getWebIfRoomInfo result")

    result
  end

  def getRoomInfoForWebIf
    result = {}

    trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

    save_data(trueSaveFileName) do |saveData|
      result['roomName'] = getHashValue(saveData, 'playRoomName', '')
      result['chatTab'] = getHashValue(saveData, 'chatChannelNames', [])
      result['outerImage'] = getHashValue(saveData, 'canUseExternalImage', false)
      result['visit'] = getHashValue(saveData, 'canVisit', false)
      result['game'] = getHashValue(saveData, 'gameType', '')
    end

    result
  end

  def getHashValue(hash, key, default)
    value = hash[key]
    value ||= default
    value
  end

  def setWebIfRoomInfo
    logging("setWebIfRoomInfo begin")

    result = {}
    result['result'] = 'OK'

    setWebIfRoomInfoCounterNames

    trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

    roomInfo = getRoomInfoForWebIf
    change_save_data(trueSaveFileName) do |saveData|
      saveData['playRoomName'] = getWebIfRequestAny(:getWebIfRequestText, 'roomName', roomInfo)
      saveData['chatChannelNames'] = getWebIfRequestAny(:getWebIfRequestArray, 'chatTab', roomInfo)
      saveData['canUseExternalImage'] = getWebIfRequestAny(:getWebIfRequestBoolean, 'outerImage', roomInfo)
      saveData['canVisit'] = getWebIfRequestAny(:getWebIfRequestBoolean, 'visit', roomInfo)
      saveData['gameType'] = getWebIfRequestAny(:getWebIfRequestText, 'game', roomInfo)
    end

    logging(result, "setWebIfRoomInfo result")

    result
  end

  def setWebIfRoomInfoCounterNames
    counterNames = getWebIfRequestArray('counter', nil, ',')
    return if (counterNames.nil?)

    changeCounterNames(counterNames)
  end

  def changeCounterNames(counterNames)
    logging(counterNames, "changeCounterNames(counterNames)")
    change_save_data(@savefiles['time']) do |saveData|
      saveData['roundTimeData'] ||= {}
      roundTimeData = saveData['roundTimeData']
      roundTimeData['counterNames'] = counterNames
    end
  end

  def getWebIfRequestAny(functionName, key, defaultInfos, key2 = nil)
    key2 ||= key

    logging("getWebIfRequestAny begin")
    logging(key, "key")
    logging(key2, "key2")
    logging(defaultInfos, "defaultInfos")

    defaultValue = defaultInfos[key2]
    logging(defaultValue, "defaultValue")

    command = "#{functionName}( key, defaultValue )"
    logging(command, "getWebIfRequestAny command")

    result = eval(command)
    logging(result, "getWebIfRequestAny result")

    result
  end


  def getWebIfRefresh
    logging("getWebIfRefresh Begin")

    chatTime = getWebIfRequestNumber('chat', -1)

    @last_update_times = {
        'chatMessageDataLog' => chatTime,
        'map' => getWebIfRequestNumber('map', -1),
        'characters' => getWebIfRequestNumber('characters', -1),
        'time' => getWebIfRequestNumber('time', -1),
        'effects' => getWebIfRequestNumber('effects', -1),
        $playRoomInfoTypeName => getWebIfRequestNumber('roomInfo', -1),
    }

    @last_update_times.delete_if { |type, time| time == -1 }
    logging(@last_update_times, "getWebIfRefresh lastUpdateTimes")

    saveData = {}
    refreshLoop(saveData)
    deleteOldChatTextForWebIf(chatTime, saveData)

    result = {}
    ["chatMessageDataLog", "mapData", "characters", "graveyard", "effects"].each do |key|
      value = saveData.delete(key)
      next if (value.nil?)

      result[key] = value
    end

    result['roomInfo'] = saveData
    result['lastUpdateTimes'] = @last_update_times
    result['result'] = 'OK'

    logging("getWebIfRefresh End result", result)

    result
  end


  def refresh()
    logging("==>Begin refresh")

    saveData = {}

    if ($isMentenanceNow)
      saveData["warning"] = {"key" => "canNotRefreshBecauseMentenanceNow"}
      return saveData
    end

    params = getParamsFromRequestData()
    logging(params, "params")

    @last_update_times = params['times']
    logging(@last_update_times, "@lastUpdateTimes")

    isFirstChatRefresh = (@last_update_times['chatMessageDataLog'] == 0)
    logging(isFirstChatRefresh, "isFirstChatRefresh")

    refreshIndex = params['rIndex']
    logging(refreshIndex, "refreshIndex")

    @isGetOwnRecord = params['isGetOwnRecord']

    if $isCommet
      refreshLoop(saveData)
    else
      refreshOnce(saveData)
    end

    uniqueId = command_sender
    userName = params['name']
    isVisiter = params['isVisiter']

    loginUserInfo = getLoginUserInfo(userName, uniqueId, isVisiter)

    unless saveData.empty?
      saveData['lastUpdateTimes'] = @last_update_times
      saveData['refreshIndex'] = refreshIndex
      saveData['loginUserInfo'] = loginUserInfo
    end

    if isFirstChatRefresh
      saveData['isFirstChatRefresh'] = isFirstChatRefresh
    end

    logging(saveData, "refresh end saveData")
    logging("==>End refresh")

    saveData
  end

  def getLoginUserInfo(userName, uniqueId, isVisiter)
    loginUserInfoSaveFile = @savedir_info.getTrueSaveFileName($loginUserInfo)
    loginUserInfo = updateLoginUserInfo(loginUserInfoSaveFile, userName, uniqueId, isVisiter)
  end


  def getParamsFromRequestData()
    params = request_data('params')
    logging(params, "params")
    params
  end


  def refreshLoop(saveData)
    now = Time.now
    whileLimitTime = now + $refreshTimeout

    logging(now, "now")
    logging(whileLimitTime, "whileLimitTime")

    while Time.now < whileLimitTime

      refreshOnce(saveData)

      break unless (saveData.empty?)

      intalval = getRefreshInterval
      logging(intalval, "saveData is empty, sleep second")
      sleep(intalval)
      logging("awake.")
    end
  end

  def getRefreshInterval
    if $isCommet
      $refreshInterval
    else
      $refreshIntervalForNotCommet
    end
  end

  def refreshOnce(saveData)
    current_save_data() do |targetSaveData, saveFileTypeName|
      saveData.merge!(targetSaveData)
    end
  end


  def updateLoginUserInfo(trueSaveFileName, userName = '', uniqueId = '', isVisiter = false)
    logging(uniqueId, 'updateLoginUserInfo uniqueId')
    logging(userName, 'updateLoginUserInfo userName')

    result = []

    return result if (uniqueId == -1)

    nowSeconds = Time.now.to_i
    logging(nowSeconds, 'nowSeconds')


    isGetOnly = (userName.empty? and uniqueId.empty?)
    getDataFunction = nil
    if isGetOnly
      getDataFunction = method(:save_data)
    else
      getDataFunction = method(:change_save_data)
    end

    getDataFunction.call(trueSaveFileName) do |saveData|

      unless isGetOnly
        changeUserInfo(saveData, uniqueId, nowSeconds, userName, isVisiter)
      end

      saveData.delete_if do |existUserId, userInfo|
        isDeleteUserInfo?(existUserId, userInfo, nowSeconds)
      end

      saveData.keys.sort.each do |userId|
        userInfo = saveData[userId]
        data = {
            "userName" => userInfo['userName'],
            "userId" => userId,
        }

        data['isVisiter'] = true if (userInfo['isVisiter'])

        result << data
      end
    end

    result
  end

  def isDeleteUserInfo?(existUserId, userInfo, nowSeconds)
    isLogout = userInfo['isLogout']
    return true if (isLogout)

    timeSeconds = userInfo['timeSeconds']
    diffSeconds = nowSeconds - timeSeconds
    (diffSeconds > $loginTimeOut)
  end

  def changeUserInfo(saveData, uniqueId, nowSeconds, userName, isVisiter)
    return if (uniqueId.empty?)

    isLogout = false
    if saveData.include?(uniqueId)
      isLogout = saveData[uniqueId]['isLogout']
    end

    return if (isLogout)

    userInfo = {
        'userName' => userName,
        'timeSeconds' => nowSeconds,
    }

    userInfo['isVisiter'] = true if (isVisiter)

    saveData[uniqueId] = userInfo
  end


  def getPlayRoomName(saveData, index)
    playRoomName = saveData['playRoomName']
    playRoomName ||= "プレイルームNo.#{index}"
    playRoomName
  end

  def getLoginUserCountList(roomNumberRange)
    loginUserCountList = {}
    roomNumberRange.each { |i| loginUserCountList[i] = 0 }

    @savedir_info.each_with_index(roomNumberRange, $loginUserInfo) do |saveFiles, index|
      next unless (roomNumberRange.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        loginUserCountList[index] = 0
        next
      end

      trueSaveFileName = saveFiles.first

      loginUserInfo = updateLoginUserInfo(trueSaveFileName)
      loginUserCountList[index] = loginUserInfo.size
    end

    loginUserCountList
  end

  def getLoginUserList(roomNumberRange)
    loginUserList = {}
    roomNumberRange.each { |i| loginUserList[i] = [] }

    @savedir_info.each_with_index(roomNumberRange, $loginUserInfo) do |saveFiles, index|
      next unless (roomNumberRange.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        #loginUserList[index] = []
        next
      end

      userNames = []
      trueSaveFileName = saveFiles.first
      loginUserInfo = updateLoginUserInfo(trueSaveFileName)
      loginUserInfo.each do |data|
        userNames << data["userName"]
      end

      loginUserList[index] = userNames
    end

    loginUserList
  end


  def getSaveDataLastAccessTimes(roomNumberRange)
    @savedir_info.getSaveDataLastAccessTimes($saveFiles.values, roomNumberRange)
  end

  def getSaveDataLastAccessTime(fileName, roomNo)
    data = @savedir_info.getSaveDataLastAccessTime(fileName, roomNo)
    time = data[roomNo]
  end


  def removeOldPlayRoom()
    roomNumberRange = (0 .. $saveDataMaxCount)
    accessTimes = getSaveDataLastAccessTimes(roomNumberRange)
    removeOldRoomFromAccessTimes(accessTimes)
  end

  def removeOldRoomFromAccessTimes(accessTimes)
    logging("removeOldRoom Begin")
    if $removeOldPlayRoomLimitDays <= 0
      return accessTimes
    end

    logging(accessTimes, "accessTimes")

    roomNumbers = getDeleteTargetRoomNumbers(accessTimes)

    ignoreLoginUser = true
    password = nil
    result = removePlayRoomByParams(roomNumbers, ignoreLoginUser, password)
    logging(result, "removePlayRoomByParams result")

    result
  end

  def getDeleteTargetRoomNumbers(accessTimes)
    logging(accessTimes, "getDeleteTargetRoomNumbers accessTimes")

    roomNumbers = []

    accessTimes.each do |index, time|
      logging(index, "index")
      logging(time, "time")

      next if (time.nil?)

      timeDiffSeconds = (Time.now - time)
      logging(timeDiffSeconds, "timeDiffSeconds")

      limitSeconds = $removeOldPlayRoomLimitDays * 24 * 60 * 60
      logging(limitSeconds, "limitSeconds")

      if timeDiffSeconds > limitSeconds
        logging(index, "roomNumbers added index")
        roomNumbers << index
      end
    end

    logging(roomNumbers, "roomNumbers")
    roomNumbers
  end


  def findEmptyRoomNumber()
    emptyRoomNubmer = -1

    roomNumberRange = (0..$saveDataMaxCount)

    roomNumberRange.each do |roomNumber|
      @savedir_info.setSaveDataDirIndex(roomNumber)
      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

      next if (exist?(trueSaveFileName))

      emptyRoomNubmer = roomNumber
      break
    end

    emptyRoomNubmer
  end

  def getPlayRoomStates()
    params = getParamsFromRequestData()
    logging(params, "params")

    minRoom = getMinRoom(params)
    maxRoom = getMaxRoom(params)
    playRoomStates = getPlayRoomStatesLocal(minRoom, maxRoom)

    result = {
        "minRoom" => minRoom,
        "maxRoom" => maxRoom,
        "playRoomStates" => playRoomStates,
    }

    logging(result, "getPlayRoomStatesLocal result")

    result
  end

  def getPlayRoomStatesLocal(minRoom, maxRoom)
    roomNumberRange = (minRoom .. maxRoom)
    playRoomStates = []

    roomNumberRange.each do |roomNo|

      @savedir_info.setSaveDataDirIndex(roomNo)

      playRoomState = getPlayRoomState(roomNo)
      next if (playRoomState.nil?)

      playRoomStates << playRoomState
    end

    playRoomStates
  end

  def getPlayRoomState(roomNo)

    # playRoomState = nil
    playRoomState = {}
    playRoomState['passwordLockState'] = false
    playRoomState['index'] = sprintf("%3d", roomNo)
    playRoomState['playRoomName'] = "（空き部屋）"
    playRoomState['lastUpdateTime'] = ""
    playRoomState['canVisit'] = false
    playRoomState['gameType'] = ''
    playRoomState['loginUsers'] = []

    begin
      playRoomState = getPlayRoomStateLocal(roomNo, playRoomState)
    rescue => e
      loggingForce("getPlayRoomStateLocal rescue")
      loggingException(e)
    rescue Exception => e
      loggingForce("getPlayRoomStateLocal Exception rescue")
      loggingException(e)
    end

    playRoomState
  end

  def getPlayRoomStateLocal(roomNo, playRoomState)
    playRoomInfoFile = @savedir_info.getTrueSaveFileName($playRoomInfo)

    return playRoomState unless (exist?(playRoomInfoFile))

    playRoomData = nil
    save_data(playRoomInfoFile) do |playRoomDataTmp|
      playRoomData = playRoomDataTmp
    end
    logging(playRoomData, "playRoomData")

    return playRoomState if (playRoomData.empty?)

    playRoomName = getPlayRoomName(playRoomData, roomNo)
    passwordLockState = (not playRoomData['playRoomChangedPassword'].nil?)
    canVisit = playRoomData['canVisit']
    gameType = playRoomData['gameType']
    timeStamp = getSaveDataLastAccessTime($saveFiles['chatMessageDataLog'], roomNo)

    timeString = ""
    unless timeStamp.nil?
      timeString = "#{timeStamp.strftime('%Y/%m/%d %H:%M:%S')}"
    end

    loginUsers = getLoginUserNames()

    playRoomState['passwordLockState'] = passwordLockState
    playRoomState['playRoomName'] = playRoomName
    playRoomState['lastUpdateTime'] = timeString
    playRoomState['canVisit'] = canVisit
    playRoomState['gameType'] = gameType
    playRoomState['loginUsers'] = loginUsers

    playRoomState
  end

  def getLoginUserNames()
    userNames = []

    trueSaveFileName = @savedir_info.getTrueSaveFileName($loginUserInfo)
    logging(trueSaveFileName, "getLoginUserNames trueSaveFileName")

    unless exist?(trueSaveFileName)
      return userNames
    end

    @now_getLoginUserNames ||= Time.now.to_i

    save_data(trueSaveFileName) do |userInfos|
      userInfos.each do |uniqueId, userInfo|
        next if (isDeleteUserInfo?(uniqueId, userInfo, @now_getLoginUserNames))
        userNames << userInfo['userName']
      end
    end

    logging(userNames, "getLoginUserNames userNames")
    userNames
  end

  def getGameName(gameType)
    require 'diceBotInfos'
    diceBotInfos = DiceBotInfos.new.getInfos
    gameInfo = diceBotInfos.find { |i| i["gameType"] == gameType }

    return '--' if (gameInfo.nil?)

    gameInfo["name"]
  end


  def getPlayRoomStatesByCount()
    params = getParamsFromRequestData()
    logging(params, "params")

    minRoom = getMinRoom(params)
    count = params["count"]
    playRoomStates = getPlayRoomStatesByCountLocal(minRoom, count)

    result = {
        "playRoomStates" => playRoomStates,
    }

    logging(result, "getPlayRoomStatesByCount result")

    result
  end

  def getPlayRoomStatesByCountLocal(startRoomNo, count)
    playRoomStates = []

    (startRoomNo .. ($saveDataMaxCount - 1)).each do |roomNo|

      break if (playRoomStates.length > count)

      @savedir_info.setSaveDataDirIndex(roomNo)

      playRoomState = getPlayRoomState(roomNo)
      next if (playRoomState.nil?)

      playRoomStates << playRoomState
    end

    playRoomStates
  end


  def getAllLoginCount()
    roomNumberRange = (0 .. $saveDataMaxCount)
    loginUserCountList = getLoginUserCountList(roomNumberRange)

    total = 0
    userList = []

    loginUserCountList.each do |key, value|
      next if (value == 0)

      total += value
      userList << [key, value]
    end

    userList.sort!

    logging(total, "getAllLoginCount total")
    logging(userList, "getAllLoginCount userList")
    return total, userList
  end

  def getFamousGames
    roomNumberRange = (0 .. $saveDataMaxCount)
    gameTypeList = getGameTypeList(roomNumberRange)

    counts = {}
    gameTypeList.each do |roomNo, gameType|
      next if (gameType.empty?)

      counts[gameType] ||= 0
      counts[gameType] += 1
    end

    logging(counts, 'counts')

    countList = counts.collect { |gameType, count| [count, gameType] }
    countList.sort!
    countList.reverse!

    logging('countList', countList)

    famousGames = []

    countList.each_with_index do |info, index|
      # next if( index >= 3 )

      count, gameType = info
      famousGames << {"gameType" => gameType, "count" => count}
    end

    logging('famousGames', famousGames)

    famousGames
  end


  def getMinRoom(params)
    minRoom = [[params['minRoom'], 0].max, ($saveDataMaxCount - 1)].min
  end

  def getMaxRoom(params)
    maxRoom = [[params['maxRoom'], ($saveDataMaxCount - 1)].min, 0].max
  end

  def getLoginInfo()
    logging("getLoginInfo begin")

    params = getParamsFromRequestData()

    uniqueId = params['uniqueId']
    uniqueId ||= createUniqueId()

    allLoginCount, loginUserCountList = getAllLoginCount()
    writeAllLoginInfo(allLoginCount)

    loginMessage = getLoginMessage()
    cardInfos = cards_info.collectCardTypeAndTypeName()
    diceBotInfos = getDiceBotInfos()

    result = {
        "loginMessage" => loginMessage,
        "cardInfos" => cardInfos,
        "isDiceBotOn" => $isDiceBotOn,
        "uniqueId" => uniqueId,
        "refreshTimeout" => $refreshTimeout,
        "refreshInterval" => getRefreshInterval(),
        "isCommet" => $isCommet,
        "version" => $version,
        "playRoomMaxNumber" => ($saveDataMaxCount - 1),
        "warning" => getLoginWarning(),
        "playRoomGetRangeMax" => $playRoomGetRangeMax,
        "allLoginCount" => allLoginCount.to_i,
        "limitLoginCount" => $limitLoginCount,
        "loginUserCountList" => loginUserCountList,
        "maxLoginCount" => $aboutMaxLoginCount.to_i,
        "skinImage" => $skinImage,
        "isPaformanceMonitor" => $isPaformanceMonitor,
        "fps" => $fps,
        "loginTimeLimitSecond" => $loginTimeLimitSecond,
        "removeOldPlayRoomLimitDays" => $removeOldPlayRoomLimitDays,
        "canTalk" => $canTalk,
        "retryCountLimit" => $retryCountLimit,
        "imageUploadDirInfo" => {$localUploadDirMarker => $imageUploadDir},
        "mapMaxWidth" => $mapMaxWidth,
        "mapMaxHeigth" => $mapMaxHeigth,
        'diceBotInfos' => diceBotInfos,
        'isNeedCreatePassword' => (not $createPlayRoomPassword.empty?),
        'defaultUserNames' => $defaultUserNames,
    }

    logging(result, "result")
    logging("getLoginInfo end")
    result
  end


  def createUniqueId
    # 識別子用の文字列生成。
    (Time.now.to_f * 1000).to_i.to_s(36)
  end

  def writeAllLoginInfo(allLoginCount)
    text = "#{allLoginCount}"

    saveFileName = $loginCountFile
    saveFileLock = real_savefile_lock_readonly(saveFileName)

    saveFileLock.lock do
      File.open(saveFileName, "w+") do |file|
        file.write(text.toutf8)
      end
    end
  end


  def getLoginWarning
    unless exist_dir?(getSmallImageDir)
      return {
          "key" => "noSmallImageDir",
          "params" => [getSmallImageDir],
      }
    end

    if ($isMentenanceNow)
      return {
          "key" => "canNotLoginBecauseMentenanceNow",
      }
    end

    nil
  end

  def getLoginMessage
    mesasge = ""
    mesasge << getLoginMessageHeader
    mesasge << getLoginMessageHistoryPart
    mesasge
  end

  def getLoginMessageHeader
    loginMessage = ""

    if File.exist?($loginMessageFile)
      File.readlines($loginMessageFile).each do |line|
        loginMessage << line.chomp << "\n"
      end
      logging(loginMessage, "loginMessage")
    else
      logging("#{$loginMessageFile} is NOT found.")
    end

    loginMessage
  end

  def getLoginMessageHistoryPart
    loginMessage = ""
    if File.exist?($loginMessageBaseFile)
      File.readlines($loginMessageBaseFile).each do |line|
        loginMessage << line.chomp << "\n"
      end
    else
      logging("#{$loginMessageFile} is NOT found.")
    end

    loginMessage
  end

  def getDiceBotInfos()
    logging("getDiceBotInfos() Begin")

    require 'diceBotInfos'
    diceBotInfos = DiceBotInfos.new.getInfos

    commandInfos = getGameCommandInfos

    commandInfos.each do |commandInfo|
      logging(commandInfo, "commandInfos.each commandInfos")
      setDiceBotPrefix(diceBotInfos, commandInfo)
    end

    logging(diceBotInfos, "getDiceBotInfos diceBotInfos")

    diceBotInfos
  end

  def setDiceBotPrefix(diceBotInfos, commandInfo)
    gameType = commandInfo["gameType"]

    if gameType.empty?
      setDiceBotPrefixToAll(diceBotInfos, commandInfo)
      return
    end

    botInfo = diceBotInfos.find { |i| i["gameType"] == gameType }
    setDiceBotPrefixToOne(botInfo, commandInfo)
  end

  def setDiceBotPrefixToAll(diceBotInfos, commandInfo)
    diceBotInfos.each do |botInfo|
      setDiceBotPrefixToOne(botInfo, commandInfo)
    end
  end

  def setDiceBotPrefixToOne(botInfo, commandInfo)
    logging(botInfo, "botInfo")
    return if (botInfo.nil?)

    prefixs = botInfo["prefixs"]
    return if (prefixs.nil?)

    prefixs << commandInfo["command"]
  end

  def getGameCommandInfos
    logging('getGameCommandInfos Begin')

    if @savedir_info.getSaveDataDirIndex == -1
      logging('getGameCommandInfos room is -1, so END')

      return []
    end

    require 'cgiDiceBot.rb'
    bot = CgiDiceBot.new
    dir = getDiceBotExtraTableDirName
    logging(dir, 'dir')

    commandInfos = bot.getGameCommandInfos(dir, @dicebot_table_prefix)
    logging(commandInfos, "getGameCommandInfos End commandInfos")

    commandInfos
  end


  def createDir(playRoomIndex)
    @savedir_info.setSaveDataDirIndex(playRoomIndex)
    @savedir_info.createDir()
  end

  def createPlayRoom()
    logging('createPlayRoom begin')

    resultText = "OK"
    playRoomIndex = -1
    begin
      params = getParamsFromRequestData()
      logging(params, "params")

      checkCreatePlayRoomPassword(params['createPassword'])

      playRoomName = params['playRoomName']
      playRoomPassword = params['playRoomPassword']
      chatChannelNames = params['chatChannelNames']
      canUseExternalImage = params['canUseExternalImage']

      canVisit = params['canVisit']
      playRoomIndex = params['playRoomIndex']

      if playRoomIndex == -1
        playRoomIndex = findEmptyRoomNumber()
        raise Exception.new("noEmptyPlayRoom") if (playRoomIndex == -1)

        logging(playRoomIndex, "findEmptyRoomNumber playRoomIndex")
      end

      logging(playRoomName, 'playRoomName')
      logging('playRoomPassword is get')
      logging(playRoomIndex, 'playRoomIndex')

      init_savefiles(playRoomIndex)
      checkSetPassword(playRoomPassword, playRoomIndex)

      logging("@saveDirInfo.removeSaveDir(playRoomIndex) Begin")
      @savedir_info.removeSaveDir(playRoomIndex)
      logging("@saveDirInfo.removeSaveDir(playRoomIndex) End")

      createDir(playRoomIndex)

      playRoomChangedPassword = getChangedPassword(playRoomPassword)
      logging(playRoomChangedPassword, 'playRoomChangedPassword')

      viewStates = params['viewStates']
      logging("viewStates", viewStates)

      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

      change_save_data(trueSaveFileName) do |saveData|
        saveData['playRoomName'] = playRoomName
        saveData['playRoomChangedPassword'] = playRoomChangedPassword
        saveData['chatChannelNames'] = chatChannelNames
        saveData['canUseExternalImage'] = canUseExternalImage
        saveData['canVisit'] = canVisit
        saveData['gameType'] = params['gameType']

        addViewStatesToSaveData(saveData, viewStates)
      end

      sendRoomCreateMessage(playRoomIndex)
    rescue => e
      loggingException(e)
      resultText = e.inspect + "$@ : " + $@.join("\n")
    rescue Exception => errorMessage
      resultText = errorMessage.to_s
    end

    result = {
        "resultText" => resultText,
        "playRoomIndex" => playRoomIndex,
    }
    logging(result, 'result')
    logging('createDir finished')

    result
  end

  def checkCreatePlayRoomPassword(password)
    logging('checkCreatePlayRoomPassword Begin')
    logging(password, 'password')

    return if ($createPlayRoomPassword.empty?)
    return if ($createPlayRoomPassword == password)

    raise Exception.new("errorPassword")
  end


  def sendRoomCreateMessage(roomNo)
    chatData = {
        "senderName" => "どどんとふ",
        "message" => "＝＝＝＝＝＝＝　プレイルーム　【　No.　#{roomNo}　】　へようこそ！　＝＝＝＝＝＝＝",
        "color" => "cc0066",
        "uniqueId" => '0',
        "channel" => 0,
    }

    sendChatMessageByChatData(chatData)
  end


  def addViewStatesToSaveData(saveData, viewStates)
    viewStates['key'] = Time.now.to_f.to_s
    saveData['viewStateInfo'] = viewStates
  end

  def getChangedPassword(pass)
    return nil if (pass.empty?)

    salt = [rand(64), rand(64)].pack("C*").tr("\x00-\x3f", "A-Za-z0-9./")
    pass.crypt(salt)
  end

  def changePlayRoom()
    logging("changePlayRoom begin")

    resultText = "OK"

    begin
      params = getParamsFromRequestData()
      logging(params, "params")

      playRoomPassword = params['playRoomPassword']
      checkSetPassword(playRoomPassword)

      playRoomChangedPassword = getChangedPassword(playRoomPassword)
      logging('playRoomPassword is get')

      viewStates = params['viewStates']
      logging("viewStates", viewStates)

      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

      change_save_data(trueSaveFileName) do |saveData|
        saveData['playRoomName'] = params['playRoomName']
        saveData['playRoomChangedPassword'] = playRoomChangedPassword
        saveData['chatChannelNames'] = params['chatChannelNames']
        saveData['canUseExternalImage'] = params['canUseExternalImage']
        saveData['canVisit'] = params['canVisit']
        saveData['backgroundImage'] = params['backgroundImage']
        saveData['gameType'] = params['gameType']

        preViewStateInfo = saveData['viewStateInfo']
        unless isSameViewState(viewStates, preViewStateInfo)
          addViewStatesToSaveData(saveData, viewStates)
        end

      end
    rescue => e
      loggingException(e)
      resultText = e.to_s
    rescue Exception => e
      loggingException(e)
      resultText = e.to_s
    end

    result = {
        "resultText" => resultText,
    }
    logging(result, 'changePlayRoom result')

    result
  end


  def checkSetPassword(playRoomPassword, roomNumber = nil)
    return if (playRoomPassword.empty?)

    if roomNumber.nil?
      roomNumber = @savedir_info.getSaveDataDirIndex
    end

    if $noPasswordPlayRoomNumbers.include?(roomNumber)
      raise Exception.new("noPasswordPlayRoomNumber")
    end
  end


  def isSameViewState(viewStates, preViewStateInfo)
    result = true

    preViewStateInfo ||= {}

    viewStates.each do |key, value|
      unless value == preViewStateInfo[key]
        result = false
        break
      end
    end

    result
  end


  def checkRemovePlayRoom(roomNumber, ignoreLoginUser, password)
    roomNumberRange = (roomNumber..roomNumber)
    logging(roomNumberRange, "checkRemovePlayRoom roomNumberRange")

    unless ignoreLoginUser
      userNames = getLoginUserNames()
      userCount = userNames.size
      logging(userCount, "checkRemovePlayRoom userCount")

      if userCount > 0
        return "userExist"
      end
    end

    if not password.nil?
      if not checkPassword(roomNumber, password)
        return "password"
      end
    end

    if $unremovablePlayRoomNumbers.include?(roomNumber)
      return "unremovablePlayRoomNumber"
    end

    lastAccessTimes = getSaveDataLastAccessTimes(roomNumberRange)
    lastAccessTime = lastAccessTimes[roomNumber]
    logging(lastAccessTime, "lastAccessTime")

    unless lastAccessTime.nil?
      now = Time.now
      spendTimes = now - lastAccessTime
      logging(spendTimes, "spendTimes")
      logging(spendTimes / 60 / 60, "spendTimes / 60 / 60")
      if (spendTimes < $deletablePassedSeconds)
        return "プレイルームNo.#{roomNumber}の最終更新時刻から#{$deletablePassedSeconds}秒が経過していないため削除できません"
      end
    end

    "OK"
  end


  def checkPassword(roomNumber, password)

    return true unless ($isPasswordNeedFroDeletePlayRoom)

    @savedir_info.setSaveDataDirIndex(roomNumber)
    trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)
    isExistPlayRoomInfo = (exist?(trueSaveFileName))

    return true unless (isExistPlayRoomInfo)

    matched = false
    save_data(trueSaveFileName) do |saveData|
      changedPassword = saveData['playRoomChangedPassword']
      matched = isPasswordMatch?(password, changedPassword)
    end

    matched
  end


  def removePlayRoom()
    params = getParamsFromRequestData()

    roomNumbers = params['roomNumbers']
    ignoreLoginUser = params['ignoreLoginUser']
    password = params['password']
    password ||= ""

    removePlayRoomByParams(roomNumbers, ignoreLoginUser, password)
  end

  def removePlayRoomByParams(roomNumbers, ignoreLoginUser, password)
    logging(ignoreLoginUser, 'removePlayRoomByParams Begin ignoreLoginUser')

    deletedRoomNumbers = []
    errorMessages = []
    passwordRoomNumbers = []
    askDeleteRoomNumbers = []

    roomNumbers.each do |roomNumber|
      roomNumber = roomNumber.to_i
      logging(roomNumber, 'roomNumber')

      resultText = checkRemovePlayRoom(roomNumber, ignoreLoginUser, password)
      logging(resultText, "checkRemovePlayRoom resultText")

      case resultText
        when "OK"
          @savedir_info.removeSaveDir(roomNumber)
          removeLocalSpaceDir(roomNumber)
          deletedRoomNumbers << roomNumber
        when "password"
          passwordRoomNumbers << roomNumber
        when "userExist"
          askDeleteRoomNumbers << roomNumber
        else
          errorMessages << resultText
      end
    end

    result = {
        "deletedRoomNumbers" => deletedRoomNumbers,
        "askDeleteRoomNumbers" => askDeleteRoomNumbers,
        "passwordRoomNumbers" => passwordRoomNumbers,
        "errorMessages" => errorMessages,
    }
    logging(result, 'result')

    result
  end

  def removeLocalSpaceDir(roomNumber)
    dir = getRoomLocalSpaceDirNameByRoomNo(roomNumber)
    rmdir(dir)
  end

  def getTrueSaveFileName(fileName)
    saveFileName = @savedir_info.getTrueSaveFileName($saveFileTempName)
  end

  def saveScenario()
    logging("saveScenario begin")
    dir = getRoomLocalSpaceDirName
    makeDir(dir)

    params = getParamsFromRequestData()
    @saveScenarioBaseUrl = params['baseUrl']
    chatPaletteSaveDataString = params['chatPaletteSaveData']

    saveDataAll = getSaveDataAllForScenario
    saveDataAll = moveAllImagesToDir(dir, saveDataAll)
    makeChatPalletSaveFile(dir, chatPaletteSaveDataString)
    makeScenariDefaultSaveFile(dir, saveDataAll)

    removeOldScenarioFile(dir)
    baseName = getNewSaveFileBaseName(@full_backup_base_name)
    scenarioFile = makeScenarioFile(dir, baseName)

    result = {}
    result['result'] = "OK"
    result["saveFileName"] = scenarioFile

    logging(result, "saveScenario result")
    result
  end

  def getSaveDataAllForScenario
    selectTypes = $saveFiles.keys
    selectTypes.delete_if { |i| i == 'chatMessageDataLog' }

    isAddPlayRoomInfo = true
    getSelectFilesData(selectTypes, isAddPlayRoomInfo)
  end

  def moveAllImagesToDir(dir, saveDataAll)
    logging(saveDataAll, 'moveAllImagesToDir saveDataAll')

    moveMapImageToDir(dir, saveDataAll)
    moveEffectsImageToDir(dir, saveDataAll)
    moveCharactersImagesToDir(dir, saveDataAll)
    movePlayroomImagesToDir(dir, saveDataAll)

    logging(saveDataAll, 'moveAllImagesToDir result saveDataAll')

    saveDataAll
  end

  def moveMapImageToDir(dir, saveDataAll)
    mapData = getLoadData(saveDataAll, 'map', 'mapData', {})
    imageSource = mapData['imageSource']

    changeFilePlace(imageSource, dir)
  end

  def moveEffectsImageToDir(dir, saveDataAll)
    effects = getLoadData(saveDataAll, 'effects', 'effects', [])

    effects.each do |effect|
      imageFile = effect['source']
      changeFilePlace(imageFile, dir)
    end
  end

  def moveCharactersImagesToDir(dir, saveDataAll)
    characters = getLoadData(saveDataAll, 'characters', 'characters', [])
    moveCharactersImagesToDirFromCharacters(dir, characters)

    characters = getLoadData(saveDataAll, 'characters', 'graveyard', [])
    moveCharactersImagesToDirFromCharacters(dir, characters)

    characters = getLoadData(saveDataAll, 'characters', 'waitingRoom', [])
    moveCharactersImagesToDirFromCharacters(dir, characters)
  end

  def moveCharactersImagesToDirFromCharacters(dir, characters)

    characters.each do |character|

      imageNames = []

      case character['type']
        when 'characterData'
          imageNames << character['imageName']
        when 'Card', 'CardMount', 'CardTrushMount'
          imageNames << character['imageName']
          imageNames << character['imageNameBack']
        when 'floorTile', 'chit'
          imageNames << character['imageUrl']
        else

      end

      next if (imageNames.empty?)

      imageNames.each do |imageName|
        changeFilePlace(imageName, dir)
      end
    end
  end

  def movePlayroomImagesToDir(dir, saveDataAll)
    logging(dir, "movePlayroomImagesToDir dir")
    playRoomInfo = saveDataAll['playRoomInfo']
    return if (playRoomInfo.nil?)
    logging(playRoomInfo, "playRoomInfo")

    backgroundImage = playRoomInfo['backgroundImage']
    logging(backgroundImage, "backgroundImage")
    return if (backgroundImage.nil?)
    return if (backgroundImage.empty?)

    changeFilePlace(backgroundImage, dir)
  end

  def changeFilePlace(from, to)
    logging(from, "changeFilePlace from")

    fromFileName, text = from.split(/\t/)
    fromFileName ||= from

    result = copyFile(fromFileName, to)
    logging(result, "copyFile result")

    return unless (result)

    from.gsub!(/.*\//, $imageUploadDirMarker + "/")
    logging(from, "changeFilePlace result")
  end

  def copyFile(from, to)
    logging("moveFile begin")
    logging(from, "from")
    logging(to, "to")

    logging(@saveScenarioBaseUrl, "@saveScenarioBaseUrl")
    from.gsub!(@saveScenarioBaseUrl, './')
    logging(from, "from2")

    return false if (from.nil?)
    return false unless (File.exist?(from))

    fromDir = File.dirname(from)
    logging(fromDir, "fromDir")
    if fromDir == to
      logging("from, to is equal dir")
      return true
    end

    logging("copying...")

    result = true
    begin
      FileUtils.cp(from, to)
    rescue => e
      result = false
    end

    result
  end

  def makeChatPalletSaveFile(dir, chatPaletteSaveDataString)
    logging("makeChatPalletSaveFile Begin")
    logging(dir, "makeChatPalletSaveFile dir")

    currentDir = FileUtils.pwd.untaint
    FileUtils.cd(dir)

    File.open($scenarioDefaultChatPallete, "a+") do |file|
      file.write(chatPaletteSaveDataString)
    end

    FileUtils.cd(currentDir)
    logging("makeChatPalletSaveFile End")
  end

  def makeScenariDefaultSaveFile(dir, saveDataAll)
    logging("makeScenariDefaultSaveFile Begin")
    logging(dir, "makeScenariDefaultSaveFile dir")

    extension = "sav"
    result = saveSelectFilesFromSaveDataAll(saveDataAll, extension)

    from = result["saveFileName"]
    to = File.join(dir, $scenarioDefaultSaveData)

    FileUtils.mv(from, to)

    logging("makeScenariDefaultSaveFile End")
  end


  def removeOldScenarioFile(dir)
    fileNames = Dir.glob("#{dir}/#{@full_backup_base_name}*#{@scenario_file_ext}")
    fileNames = fileNames.collect { |i| i.untaint }
    logging(fileNames, "removeOldScenarioFile fileNames")

    fileNames.each do |fileName|
      File.delete(fileName)
    end
  end

  def makeScenarioFile(dir, fileBaseName = "scenario")
    logging("makeScenarioFile begin")

    require 'zlib'
    require 'archive/tar/minitar'

    currentDir = FileUtils.pwd.untaint
    FileUtils.cd(dir)

    scenarioFile = fileBaseName + @scenario_file_ext
    tgz = Zlib::GzipWriter.new(File.open(scenarioFile, 'wb'))

    fileNames = Dir.glob('*')
    fileNames = fileNames.collect { |i| i.untaint }

    fileNames.delete_if { |i| i == scenarioFile }

    Archive::Tar::Minitar.pack(fileNames, tgz)

    FileUtils.cd(currentDir)

    File.join(dir, scenarioFile)
  end


  def save()
    isAddPlayRoomInfo = true
    extension = request_data('extension')
    saveSelectFiles($saveFiles.keys, extension, isAddPlayRoomInfo)
  end

  def saveMap()
    extension = request_data('extension')
    selectTypes = ['map', 'characters']
    saveSelectFiles(selectTypes, extension)
  end


  def saveSelectFiles(selectTypes, extension, isAddPlayRoomInfo = false)
    saveDataAll = getSelectFilesData(selectTypes, isAddPlayRoomInfo)
    saveSelectFilesFromSaveDataAll(saveDataAll, extension)
  end

  def saveSelectFilesFromSaveDataAll(saveDataAll, extension)
    result = {}
    result["result"] = "unknown error"

    if saveDataAll.empty?
      result["result"] = "no save data"
      return result
    end

    deleteOldSaveFile

    saveData = {}
    saveData['saveDataAll'] = saveDataAll

    text = build_json(saveData)
    saveFileName = getNewSaveFileName(extension)
    create_savefile(saveFileName, text)

    result["result"] = "OK"
    result["saveFileName"] = saveFileName
    logging(result, "saveSelectFiles result")

    result
  end


  def getSelectFilesData(selectTypes, isAddPlayRoomInfo = false)
    logging("getSelectFilesData begin")

    @last_update_times = {}
    selectTypes.each do |type|
      @last_update_times[type] = 0
    end
    logging("dummy @lastUpdateTimes created")

    saveDataAll = {}
    current_save_data() do |targetSaveData, saveFileTypeName|
      saveDataAll[saveFileTypeName] = targetSaveData
      logging(saveFileTypeName, "saveFileTypeName in save")
    end

    if isAddPlayRoomInfo
      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)
      @last_update_times[$playRoomInfoTypeName] = 0
      if isSaveFileChanged(0, trueSaveFileName)
        saveDataAll[$playRoomInfoTypeName] = load_savefile($playRoomInfoTypeName, trueSaveFileName)
      end
    end

    logging(saveDataAll, "saveDataAll tmp")

    saveDataAll
  end

  #override
  def fileJoin(*parts)
    File.join(*parts)
  end

  def getNewSaveFileName(extension)
    baseName = getNewSaveFileBaseName("DodontoF")
    saveFileName = baseName + ".#{extension}"
    fileJoin($saveDataTempDir, saveFileName).untaint
  end

  def getNewSaveFileBaseName(prefix)
    now = Time.now
    baseName = now.strftime(prefix + "_%Y_%m%d_%H%M%S_#{now.usec}")
    baseName.untaint
  end


  def deleteOldSaveFile
    logging('deleteOldSaveFile begin')
    begin
      deleteOldSaveFileCatched
    rescue => e
      loggingException(e)
    end
    logging('deleteOldSaveFile end')
  end

  def deleteOldSaveFileCatched

    change_save_data($saveFileNames) do |saveData|
      existSaveFileNames = saveData["fileNames"]
      existSaveFileNames ||= []
      logging(existSaveFileNames, 'existSaveFileNames')

      regExp = /DodontoF_[\d_]+.sav/

      deleteTargets = []

      existSaveFileNames.each do |saveFileName|
        logging(saveFileName, 'saveFileName')
        next unless (regExp === saveFileName)

        createdTime = getSaveFileTimeStamp(saveFileName)
        now = Time.now.to_i
        diff = (now - createdTime)
        logging(diff, "createdTime diff")
        next if (diff < $oldSaveFileDelteSeconds)

        begin
          deleteFile(saveFileName)
        rescue => e
          loggingException(e)
        end

        deleteTargets << saveFileName
      end

      logging(deleteTargets, "deleteTargets")

      deleteTargets.each do |fileName|
        existSaveFileNames.delete_if { |i| i == fileName }
      end
      logging(existSaveFileNames, "existSaveFileNames")

      saveData["fileNames"] = existSaveFileNames
    end

  end


  def loggingException(e)
    self.class.loggingException(e)
  end

  def self.loggingException(e)
    loggingForce(e.to_s, "exception mean")
    loggingForce($@.join("\n"), "exception from")
    loggingForce($!.inspect, "$!.inspect")
  end


  def checkRoomStatus()
    deleteOldUploadFile()

    checkRoomStatusData = getParamsFromRequestData()
    logging(checkRoomStatusData, 'checkRoomStatusData')

    roomNumber = checkRoomStatusData['roomNumber']
    logging(roomNumber, 'roomNumber')

    @savedir_info.setSaveDataDirIndex(roomNumber)

    isMentenanceModeOn = false;
    isWelcomeMessageOn = $isWelcomeMessageOn;
    playRoomName = ''
    chatChannelNames = nil
    canUseExternalImage = false
    canVisit = false
    isPasswordLocked = false
    trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)
    isExistPlayRoomInfo = (exist?(trueSaveFileName))

    if isExistPlayRoomInfo
      save_data(trueSaveFileName) do |saveData|
        playRoomName = getPlayRoomName(saveData, roomNumber)
        changedPassword = saveData['playRoomChangedPassword']
        chatChannelNames = saveData['chatChannelNames']
        canUseExternalImage = saveData['canUseExternalImage']
        canVisit = saveData['canVisit']
        unless changedPassword.nil?
          isPasswordLocked = true
        end
      end
    end

    unless $mentenanceModePassword.nil?
      if checkRoomStatusData["adminPassword"] == $mentenanceModePassword
        isPasswordLocked = false
        isWelcomeMessageOn = false
        isMentenanceModeOn = true
      end
    end

    logging("isPasswordLocked", isPasswordLocked)

    result = {
        'isRoomExist' => isExistPlayRoomInfo,
        'roomName' => playRoomName,
        'roomNumber' => roomNumber,
        'chatChannelNames' => chatChannelNames,
        'canUseExternalImage' => canUseExternalImage,
        'canVisit' => canVisit,
        'isPasswordLocked' => isPasswordLocked,
        'isMentenanceModeOn' => isMentenanceModeOn,
        'isWelcomeMessageOn' => isWelcomeMessageOn,
    }

    logging(result, "checkRoomStatus End result")

    result
  end

  def loginPassword()
    loginData = getParamsFromRequestData()
    logging(loginData, 'loginData')

    roomNumber = loginData['roomNumber']
    password = loginData['password']
    visiterMode = loginData['visiterMode']

    checkLoginPassword(roomNumber, password, visiterMode)
  end

  def checkLoginPassword(roomNumber, password, visiterMode)
    logging("checkLoginPassword roomNumber", roomNumber)
    @savedir_info.setSaveDataDirIndex(roomNumber)
    dirName = @savedir_info.getDirName()

    result = {
        'resultText' => '',
        'visiterMode' => false,
        'roomNumber' => roomNumber,
    }

    isRoomExist = (exist_dir?(dirName))

    unless isRoomExist
      result['resultText'] = "プレイルームNo.#{roomNumber}は作成されていません"
      return result
    end


    trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)

    save_data(trueSaveFileName) do |saveData|
      canVisit = saveData['canVisit']
      if canVisit and visiterMode
        result['resultText'] = "OK"
        result['visiterMode'] = true
      else
        changedPassword = saveData['playRoomChangedPassword']
        if isPasswordMatch?(password, changedPassword)
          result['resultText'] = "OK"
        else
          result['resultText'] = "パスワードが違います"
        end
      end
    end

    result
  end

  def isPasswordMatch?(password, changedPassword)
    return true if (changedPassword.nil?)
    (password.crypt(changedPassword) == changedPassword)
  end


  def logout()
    logoutData = getParamsFromRequestData()
    logging(logoutData, 'logoutData')

    uniqueId = logoutData['uniqueId']
    logging(uniqueId, 'uniqueId');

    trueSaveFileName = @savedir_info.getTrueSaveFileName($loginUserInfo)
    change_save_data(trueSaveFileName) do |saveData|
      saveData.each do |existUserId, userInfo|
        logging(existUserId, "existUserId in logout check")
        logging(uniqueId, 'uniqueId in logout check')

        if existUserId == uniqueId
          userInfo['isLogout'] = true
        end
      end

      logging(saveData, 'saveData in logout')
    end
  end


  def checkFileSizeOnMb(data, size_MB)
    error = false

    limit = (size_MB * 1024 * 1024)

    if data.size > limit
      error = true
    end

    if error
      return "ファイルサイズが最大値(#{size_MB}MB)以上のためアップロードに失敗しました。"
    end

    ""
  end


  def getBotTableInfos()
    logging("getBotTableInfos Begin")
    result = {
        "resultText" => "OK",
    }

    dir = getDiceBotExtraTableDirName
    result["tableInfos"] = getBotTableInfosFromDir(dir)

    logging(result, "result")
    logging("getBotTableInfos End")
    result
  end

  def getBotTableInfosFromDir(dir)
    logging(dir, 'getBotTableInfosFromDir dir')

    require 'TableFileData'

    isLoadCommonTable = false
    tableFileData = TableFileData.new(isLoadCommonTable)
    tableFileData.setDir(dir, @dicebot_table_prefix)
    tableInfos = tableFileData.getAllTableInfo

    logging(tableInfos, "getBotTableInfosFromDir tableInfos")
    tableInfos.sort! { |a, b| a["command"].to_i <=> b["command"].to_i }

    logging(tableInfos, 'getBotTableInfosFromDir result tableInfos')

    tableInfos
  end


  def addBotTable()
    result = {}
    result['resultText'] = addBotTableMain()

    if result['resultText'] != "OK"
      return result
    end

    logging("addBotTableMain called")

    result = getBotTableInfos()
    logging(result, "addBotTable result")

    result
  end

  def addBotTableMain()
    logging("addBotTableMain Begin")

    dir = getDiceBotExtraTableDirName
    makeDir(dir)
    params = getParamsFromRequestData()

    require 'TableFileData'

    resultText = 'OK'
    begin
      creator = TableFileCreator.new(dir, @dicebot_table_prefix, params)
      creator.execute
    rescue Exception => e
      loggingException(e)
      resultText = e.to_s
    end

    logging(resultText, "addBotTableMain End resultText")

    resultText
  end


  def changeBotTable()
    result = {}
    result['resultText'] = changeBotTableMain()

    if result['resultText'] != "OK"
      return result
    end

    getBotTableInfos()
  end

  def changeBotTableMain()
    logging("changeBotTableMain Begin")

    dir = getDiceBotExtraTableDirName
    params = getParamsFromRequestData()

    require 'TableFileData'

    resultText = 'OK'
    begin
      creator = TableFileEditer.new(dir, @dicebot_table_prefix, params)
      creator.execute
    rescue Exception => e
      loggingException(e)
      resultText = e.to_s
    end

    logging(resultText, "changeBotTableMain End resultText")

    resultText
  end


  def removeBotTable()
    removeBotTableMain()
    getBotTableInfos()
  end

  def removeBotTableMain()
    logging("removeBotTableMain Begin")

    params = getParamsFromRequestData()
    command = params["command"]

    dir = getDiceBotExtraTableDirName

    require 'TableFileData'

    isLoadCommonTable = false
    tableFileData = TableFileData.new(isLoadCommonTable)
    tableFileData.setDir(dir, @dicebot_table_prefix)
    tableInfos = tableFileData.getAllTableInfo

    tableInfo = tableInfos.find { |i| i["command"] == command }
    logging(tableInfo, "tableInfo")
    return if (tableInfo.nil?)

    fileName = tableInfo["fileName"]
    logging(fileName, "fileName")
    return if (fileName.nil?)

    logging("isFile exist?")
    return unless (File.exist?(fileName))

    begin
      File.delete(fileName)
    rescue Exception => e
      loggingException(e)
    end

    logging("removeBotTableMain End")
  end


  def requestReplayDataList()
    logging("requestReplayDataList begin")
    result = {
        "resultText" => "OK",
    }

    result["replayDataList"] = getReplayDataList() #[{"title"=>x, "url"=>y}]

    logging(result, "result")
    logging("requestReplayDataList end")
    result
  end

  def uploadReplayData()
    uploadFileBase($replayDataUploadDir, $UPLOAD_REPALY_DATA_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|
      logging("uploadReplayData yield Begin")

      params = getParamsFromRequestData()

      ownUrl = params['ownUrl']
      replayUrl = ownUrl + "?replay=" + CGI.escape(fileNameFullPath)

      replayDataName = params['replayDataName']
      replayDataInfo = setReplayDataInfo(fileNameFullPath, replayDataName, replayUrl)

      result["replayDataInfo"] = replayDataInfo
      result["replayDataList"] = getReplayDataList() #[{"title"=>x, "url"=>y}]

      logging("uploadReplayData yield End")
    end

  end

  def getReplayDataList
    replayDataList = nil

    save_data(getReplayDataInfoFileName()) do |saveData|
      replayDataList = saveData['replayDataList']
    end

    replayDataList ||= []

    replayDataList
  end

  def getReplayDataInfoFileName
    infoFileName = fileJoin($replayDataUploadDir, 'replayDataInfo.json')
    infoFileName
  end


  #getImageInfoFileName() ) do |saveData|
  def setReplayDataInfo(fileName, title, url)

    replayDataInfo = {
        "fileName" => fileName,
        "title" => title,
        "url" => url,
    }

    change_save_data(getReplayDataInfoFileName()) do |saveData|
      saveData['replayDataList'] ||= []
      replayDataList = saveData['replayDataList']
      replayDataList << replayDataInfo
    end

    replayDataInfo
  end


  def removeReplayData()
    logging("removeReplayData begin")

    result = {
        "resultText" => "NG",
    }

    begin
      replayData = getParamsFromRequestData()

      logging(replayData, "replayData")

      replayDataList = []
      change_save_data(getReplayDataInfoFileName()) do |saveData|
        saveData['replayDataList'] ||= []
        replayDataList = saveData['replayDataList']

        replayDataList.delete_if do |i|
          if (i['url'] == replayData['url']) and (i['title'] == replayData['title'])
            deleteFile(i['fileName'])
            true
          else
            false
          end
        end
      end

      logging("removeReplayData replayDataList", replayDataList)

      result = requestReplayDataList()
    rescue => e
      result["resultText"] = e.to_s
      loggingException(e)
    end

    result
  end


  def uploadFile()
    uploadFileBase($fileUploadDir, $UPLOAD_FILE_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|

      deleteOldUploadFile()

      params = getParamsFromRequestData()
      baseUrl = params['baseUrl']
      logging(baseUrl, "baseUrl")

      fileUploadUrl = baseUrl + fileNameFullPath

      result["uploadFileInfo"] = {
          "fileName" => fileNameOriginal,
          "fileUploadUrl" => fileUploadUrl,
      }
    end
  end


  def deleteOldUploadFile()
    deleteOldFile($fileUploadDir, $uploadFileTimeLimitSeconds, File.join($fileUploadDir, "dummy.txt"))
  end

  def deleteOldFile(saveDir, limitSecond, excludeFileName = nil)
    begin
      limitTime = (Time.now.to_i - limitSecond)
      fileNames = Dir.glob(File.join(saveDir, "*"))
      fileNames.delete_if { |i| i == excludeFileName }

      fileNames.each do |fileName|
        fileName = fileName.untaint
        timeStamp = File.mtime(fileName).to_i
        next if (timeStamp >= limitTime)

        File.delete(fileName)
      end
    rescue => e
      loggingException(e)
    end
  end


  def uploadFileBase(fileUploadDir, fileMaxSize, isChangeFileName = true)
    logging("uploadFile() Begin")

    result = {
        "resultText" => "NG",
    }

    begin

      unless File.exist?(fileUploadDir)
        result["resultText"] = "#{fileUploadDir}が存在しないためアップロードに失敗しました。"
        return result
      end

      params = getParamsFromRequestData()

      fileData = params['fileData']

      sizeCheckResult = checkFileSizeOnMb(fileData, fileMaxSize)
      if sizeCheckResult != ""
        result["resultText"] = sizeCheckResult
        return result
      end

      fileNameOriginal = params['fileName'].toutf8

      fileName = fileNameOriginal
      if isChangeFileName
        fileName = getNewFileName(fileNameOriginal)
      end

      fileNameFullPath = fileJoin(fileUploadDir, fileName).untaint
      logging(fileNameFullPath, "fileNameFullPath")

      yield(fileNameFullPath, fileNameOriginal, result)

      open(fileNameFullPath, "w+") do |file|
        file.binmode
        file.write(fileData)
      end
      File.chmod(0666, fileNameFullPath)

      result["resultText"] = "OK"
    rescue => e
      logging(e, "error")
      result["resultText"] = e.to_s
    end

    logging(result, "load result")
    logging("uploadFile() End")

    result
  end


  def loadScenario()
    logging("loadScenario() Begin")
    checkLoad()

    set_record_empty

    fileUploadDir = getRoomLocalSpaceDirName

    clearDir(fileUploadDir)
    makeDir(fileUploadDir)

    fileMaxSize = $scenarioDataMaxSize # Mbyte
    scenarioFile = nil
    isChangeFileName = false

    result = uploadFileBase(fileUploadDir, fileMaxSize, isChangeFileName) do |fileNameFullPath, fileNameOriginal, result|
      scenarioFile = fileNameFullPath
    end

    logging(result, "uploadFileBase result")

    unless result["resultText"] == 'OK'
      return result
    end

    extendSaveData(scenarioFile, fileUploadDir)

    chatPaletteSaveData = loadScenarioDefaultInfo(fileUploadDir)
    result['chatPaletteSaveData'] = chatPaletteSaveData

    logging(result, 'loadScenario result')

    result
  end

  def clearDir(dir)
    logging(dir, "clearDir dir")

    unless File.exist?(dir)
      return
    end

    unless File.directory?(dir)
      File.delete(dir)
      return
    end

    files = Dir.glob(File.join(dir, "*"))
    files.each do |file|
      File.delete(file.untaint)
    end
  end

  def extendSaveData(scenarioFile, fileUploadDir)
    logging(scenarioFile, 'scenarioFile')
    logging(fileUploadDir, 'fileUploadDir')

    require 'zlib'
    require 'archive/tar/minitar'

    readScenarioTar(scenarioFile) do |tar|
      logging("begin read scenario tar file")

      Archive::Tar::Minitar.unpackWithCheck(tar, fileUploadDir) do |fileName, isDirectory|
        checkUnpackFile(fileName, isDirectory)
      end
    end

    File.delete(scenarioFile)

    logging("archive extend !")
  end

  def readScenarioTar(scenarioFile)

    begin
      File.open(scenarioFile, 'rb') do |file|
        tar = file
        tar = Zlib::GzipReader.new(file)

        logging("scenarioFile is gzip")
        yield(tar)

      end
    rescue
      File.open(scenarioFile, 'rb') do |file|
        tar = file

        logging("scenarioFile is tar")
        yield(tar)

      end
    end
  end


  #直下のファイルで許容する拡張子の場合かをチェック
  def checkUnpackFile(fileName, isDirectory)
    logging(fileName, 'checkUnpackFile fileName')
    logging(isDirectory, 'checkUnpackFile isDirectory')

    if isDirectory
      logging('isDirectory!')
      return false
    end

    result = isAllowdUnpackFile(fileName)
    logging(result, 'checkUnpackFile result')

    result
  end

  def isAllowdUnpackFile(fileName)

    if /\// =~ fileName
      loggingForce(fileName, 'NG! checkUnpackFile /\// paturn')
      return false
    end

    if isAllowedFileExt(fileName)
      return true
    end

    loggingForce(fileName, 'NG! checkUnpackFile else paturn')

    false
  end

  def isAllowedFileExt(fileName)
    extName = getAllowedFileExtName(fileName)
    (not extName.nil?)
  end

  def getAllowedFileExtName(fileName)
    rule = /\.(jpg|jpeg|gif|png|bmp|pdf|doc|txt|html|htm|xls|rtf|zip|lzh|rar|swf|flv|avi|mp4|mp3|wmv|wav|sav|cpd)$/

    return nil unless (rule === fileName)

    extName = "." + $1
  end

  def getRoomLocalSpaceDirName
    roomNo = @savedir_info.getSaveDataDirIndex
    getRoomLocalSpaceDirNameByRoomNo(roomNo)
  end

  def getRoomLocalSpaceDirNameByRoomNo(roomNo)
    dir = File.join($imageUploadDir, "room_#{roomNo}")
  end

  def makeDir(dir)
    logging(dir, "makeDir dir")

    if File.exist?(dir) && File.directory?(dir)
      return
    else
      File.delete(dir)
    end

    Dir::mkdir(dir)
    File.chmod(0777, dir)
  end

  def rmdir(dir)
    SaveDirInfo.removeDir(dir)
  end

  $scenarioDefaultSaveData = 'default.sav'
  $scenarioDefaultChatPallete = 'default.cpd'

  def loadScenarioDefaultInfo(dir)
    loadScenarioDefaultSaveData(dir)
    chatPaletteSaveData = loadScenarioDefaultChatPallete(dir)

    chatPaletteSaveData
  end

  def loadScenarioDefaultSaveData(dir)
    logging('loadScenarioDefaultSaveData begin')
    saveFile = File.join(dir, $scenarioDefaultSaveData)

    unless File.exist?(saveFile)
      logging(saveFile, 'saveFile is NOT exist')
      return
    end

    jsonDataString = File.readlines(saveFile).join
    loadFromJsonDataString(jsonDataString)

    logging('loadScenarioDefaultSaveData end')
  end


  def loadScenarioDefaultChatPallete(dir)
    file = File.join(dir, $scenarioDefaultChatPallete)
    logging(file, 'loadScenarioDefaultChatPallete file')

    return nil unless (File.exist?(file))

    buffer = File.readlines(file).join
    logging(buffer, 'loadScenarioDefaultChatPallete buffer')

    buffer
  end


  def load()
    logging("saveData load() Begin")

    result = {}

    begin
      checkLoad()

      set_record_empty

      params = getParamsFromRequestData()
      logging(params, 'load params')

      jsonDataString = params['fileData']
      logging(jsonDataString, 'jsonDataString')

      result = loadFromJsonDataString(jsonDataString)

    rescue => e
      result["resultText"] = e.to_s
    end

    logging(result, "load result")

    result
  end


  def checkLoad()
    roomNumber = @savedir_info.getSaveDataDirIndex

    if $unloadablePlayRoomNumbers.include?(roomNumber)
      raise "unloadablePlayRoomNumber"
    end
  end


  def changeLoadText(text)
    text = changeTextForLocalSpaceDir(text)
  end

  def changeTextForLocalSpaceDir(text)
    #プレイルームにローカルなファイルを置く場合の特殊処理用ディレクトリ名変換
    dir = getRoomLocalSpaceDirName
    dirJsonText = JsonBuilder.new.build(dir)
    changedDir = dirJsonText[2...-2]

    logging(changedDir, 'localSpace name')

    text = text.gsub($imageUploadDirMarker, changedDir)
  end


  def loadFromJsonDataString(jsonDataString)
    jsonDataString = changeLoadText(jsonDataString)

    jsonData = parse_json(jsonDataString)
    loadFromJsonData(jsonData)
  end

  def loadFromJsonData(jsonData)
    logging(jsonData, 'loadFromJsonData jsonData')

    saveDataAll = getSaveDataAllFromSaveData(jsonData)
    params = getParamsFromRequestData()

    removeCharacterDataList = params['removeCharacterDataList']
    if removeCharacterDataList != nil
      removeCharacterByRemoveCharacterDataList(removeCharacterDataList)
    end

    targets = params['targets']
    logging(targets, "targets")

    if targets.nil?
      logging("loadSaveFileDataAll(saveDataAll)")
      loadSaveFileDataAll(saveDataAll)
    else
      logging("loadSaveFileDataFilterByTargets(saveDataAll, targets)")
      loadSaveFileDataFilterByTargets(saveDataAll, targets)
    end

    result = {
        "resultText" => "OK"
    }

    logging(result, "loadFromJsonData result")

    result
  end

  def getSaveDataAllFromSaveData(jsonData)
    jsonData['saveDataAll']
  end

  def getLoadData(saveDataAll, fileType, key, defaultValue)
    saveFileData = saveDataAll[fileType]
    return defaultValue if (saveFileData.nil?)

    data = saveFileData[key]
    return defaultValue if (data.nil?)

    data.clone
  end

  def loadCharacterDataList(saveDataAll, type)
    characterDataList = getLoadData(saveDataAll, 'characters', 'characters', [])
    logging(characterDataList, "characterDataList")

    characterDataList = characterDataList.delete_if { |i| (i["type"] != type) }
    addCharacterData(characterDataList)
  end

  def loadSaveFileDataFilterByTargets(saveDataAll, targets)
    targets.each do |target|
      logging(target, 'loadSaveFileDataFilterByTargets each target')

      case target
        when "map"
          mapData = getLoadData(saveDataAll, 'map', 'mapData', {})
          changeMapSaveData(mapData)
        when "characterData", "mapMask", "mapMarker", "magicRangeMarker", "magicRangeMarkerDD4th", "Memo", getCardType()
          loadCharacterDataList(saveDataAll, target)
        when "characterWaitingRoom"
          logging("characterWaitingRoom called")
          waitingRoom = getLoadData(saveDataAll, 'characters', 'waitingRoom', [])
          setWaitingRoomInfo(waitingRoom)
        when "standingGraphicInfos"
          effects = getLoadData(saveDataAll, 'effects', 'effects', [])
          effects = effects.delete_if { |i| (i["type"] != target) }
          logging(effects, "standingGraphicInfos effects");
          addEffectData(effects)
        when "cutIn"
          effects = getLoadData(saveDataAll, 'effects', 'effects', [])
          effects = effects.delete_if { |i| (i["type"] != nil) }
          addEffectData(effects)
        when "initiative"
          roundTimeData = getLoadData(saveDataAll, 'time', 'roundTimeData', {})
          changeInitiativeData(roundTimeData)
        else
          loggingForce(target, "invalid load target type")
      end
    end
  end

  def loadSaveFileDataAll(saveDataAll)
    logging("loadSaveFileDataAll(saveDataAll) begin")

    @savefiles.each do |fileTypeName, trueSaveFileName|
      logging(fileTypeName, "fileTypeName")
      logging(trueSaveFileName, "trueSaveFileName")

      saveDataForType = saveDataAll[fileTypeName]
      saveDataForType ||= {}
      logging(saveDataForType, "saveDataForType")

      loadSaveFileDataForEachType(fileTypeName, trueSaveFileName, saveDataForType)
    end

    if saveDataAll.include?($playRoomInfoTypeName)
      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)
      saveDataForType = saveDataAll[$playRoomInfoTypeName]
      loadSaveFileDataForEachType($playRoomInfoTypeName, trueSaveFileName, saveDataForType)
    end

    logging("loadSaveFileDataAll(saveDataAll) end")
  end


  def loadSaveFileDataForEachType(fileTypeName, trueSaveFileName, saveDataForType)

    change_save_data(trueSaveFileName) do |saveDataCurrent|
      logging(saveDataCurrent, "before saveDataCurrent")
      saveDataCurrent.clear

      saveDataForType.each do |key, value|
        logging(key, "saveDataForType.each key")
        logging(value, "saveDataForType.each value")
        saveDataCurrent[key] = value
      end
      logging(saveDataCurrent, "after saveDataCurrent")
    end

  end


  def getSmallImageDir
    saveDir = $imageUploadDir
    smallImageDirName = "smallImages"
    smallImageDir = fileJoin(saveDir, smallImageDirName)

    smallImageDir
  end

  def saveSmallImage(smallImageData, imageFileNameBase, uploadImageFileName)
    logging("saveSmallImage begin")
    logging(imageFileNameBase, "imageFileNameBase")
    logging(uploadImageFileName, "uploadImageFileName")

    smallImageDir = getSmallImageDir
    uploadSmallImageFileName = fileJoin(smallImageDir, imageFileNameBase)
    uploadSmallImageFileName += ".png"
    uploadSmallImageFileName.untaint
    logging(uploadSmallImageFileName, "uploadSmallImageFileName")

    open(uploadSmallImageFileName, "wb+") do |file|
      file.write(smallImageData)
    end
    logging("small image create successed.")

    params = getParamsFromRequestData()
    tagInfo = params['tagInfo']
    logging(tagInfo, "uploadImageData tagInfo")

    tagInfo["smallImage"] = uploadSmallImageFileName
    logging(tagInfo, "uploadImageData tagInfo smallImage url added")

    margeTagInfo(tagInfo, uploadImageFileName)
    logging(tagInfo, "saveSmallImage margeTagInfo tagInfo")
    changeImageTagsLocal(uploadImageFileName, tagInfo)

    logging("saveSmallImage end")
  end

  def margeTagInfo(tagInfo, source)
    logging(source, "margeTagInfo source")
    imageTags = getImageTags()
    tagInfo_old = imageTags[source]
    logging(tagInfo_old, "margeTagInfo tagInfo_old")
    return if (tagInfo_old.nil?)

    tagInfo_old.keys.each do |key|
      tagInfo[key] = tagInfo_old[key]
    end

    logging(tagInfo, "margeTagInfo tagInfo")
  end

  def uploadImageData()
    logging("uploadImageData load Begin")

    result = {
        "resultText" => "OK"
    }

    begin
      params = getParamsFromRequestData()

      imageFileName = params["imageFileName"]
      logging(imageFileName, "imageFileName")

      imageData = getImageDataFromParams(params, "imageData")
      smallImageData = getImageDataFromParams(params, "smallImageData")

      if imageData.nil?
        logging("createSmallImage is here")
        imageFileNameBase = File.basename(imageFileName)
        saveSmallImage(smallImageData, imageFileNameBase, imageFileName)
        return result
      end

      saveDir = $imageUploadDir
      imageFileNameBase = getNewFileName(imageFileName, "img")
      logging(imageFileNameBase, "imageFileNameBase")

      uploadImageFileName = fileJoin(saveDir, imageFileNameBase)
      logging(uploadImageFileName, "uploadImageFileName")

      open(uploadImageFileName, "wb+") do |file|
        file.write(imageData)
      end

      saveSmallImage(smallImageData, imageFileNameBase, uploadImageFileName)
    rescue => e
      result["resultText"] = e.to_s
    end

    result
  end


  def getImageDataFromParams(params, key)
    value = params[key]

    sizeCheckResult = checkFileSizeOnMb(value, $UPLOAD_IMAGE_MAX_SIZE)
    raise sizeCheckResult unless (sizeCheckResult.empty?)

    value
  end


  def getNewFileName(fileName, preFix = "")
    @newFileNameIndex ||= 0

    extName = getAllowedFileExtName(fileName)
    extName ||= ""
    logging(extName, "extName")

    result = preFix + Time.now.to_f.to_s.gsub(/\./, '_') + "_" + @newFileNameIndex.to_s + extName

    result.untaint
  end

  def deleteImage()
    logging("deleteImage begin")

    imageData = getParamsFromRequestData()
    logging(imageData, "imageData")

    imageUrlList = imageData['imageUrlList']
    logging(imageUrlList, "imageUrlList")

    imageFiles = getAllImageFileNameFromTagInfoFile()
    addLocalImageToList(imageFiles)
    logging(imageFiles, "imageFiles")

    imageUrlFileName = $imageUrlText
    logging(imageUrlFileName, "imageUrlFileName")

    deleteCount = 0
    resultText = ""
    imageUrlList.each do |imageUrl|
      if isProtectedImage(imageUrl)
        warningMessage = "#{imageUrl}は削除できない画像です。"
        next
      end

      imageUrl.untaint
      deleteResult1 = deleteImageTags(imageUrl)
      deleteResult2 = deleteTargetImageUrl(imageUrl, imageFiles, imageUrlFileName)
      deleteResult = (deleteResult1 or deleteResult2)

      if deleteResult
        deleteCount += 1
      else
        warningMessage = "不正な操作です。あなたが削除しようとしたファイル(#{imageUrl})はイメージファイルではありません。"
        loggingForce(warningMessage)
        resultText += warningMessage
      end
    end

    resultText += "#{deleteCount}個のファイルを削除しました。"
    result = {"resultText" => resultText}
    logging(result, "result")

    logging("deleteImage end")
    result
  end

  def isProtectedImage(imageUrl)
    $protectImagePaths.each do |url|
      if imageUrl.index(url) == 0
        return true
      end
    end

    false
  end

  def deleteTargetImageUrl(imageUrl, imageFiles, imageUrlFileName)
    logging(imageUrl, "deleteTargetImageUrl(imageUrl)")

    if imageFiles.include?(imageUrl) && exist?(imageUrl)
        deleteFile(imageUrl)
        return true
    end

    locker = savefile_lock(imageUrlFileName)
    locker.lock do
      lines = readlines(imageUrlFileName)
      logging(lines, "lines")

      deleteResult = lines.reject! { |i| i.chomp == imageUrl }

      unless deleteResult
        return false
      end

      logging(lines, "lines deleted")
      create_file(imageUrlFileName, lines.join)
    end

    true
  end

  #override
  def addTextToFile(fileName, text)
    File.open(fileName, "a+") do |file|
      file.write(text)
    end
  end

  def uploadImageUrl()
    logging("uploadImageUrl begin")

    imageData = getParamsFromRequestData()
    logging(imageData, "imageData")

    imageUrl = imageData['imageUrl']
    logging(imageUrl, "imageUrl")

    imageUrlFileName = $imageUrlText
    logging(imageUrlFileName, "imageUrlFileName")

    resultText = "画像URLのアップロードに失敗しました。"
    locker = savefile_lock(imageUrlFileName)
    locker.lock do
      alreadyExistUrls = readlines(imageUrlFileName).collect { |i| i.chomp }
      if alreadyExistUrls.include?(imageUrl)
        resultText = "すでに登録済みの画像URLです。"
      else
        addTextToFile(imageUrlFileName, (imageUrl + "\n"))
        resultText = "画像URLのアップロードに成功しました。"
      end
    end

    tagInfo = imageData['tagInfo']
    logging(tagInfo, 'uploadImageUrl.tagInfo')
    changeImageTagsLocal(imageUrl, tagInfo)

    logging("uploadImageUrl end")

    {"resultText" => resultText}
  end


  def getGraveyardCharacterData()
    logging("getGraveyardCharacterData start.")
    result = []

    save_data(@savefiles['characters']) do |saveData|
      graveyard = saveData['graveyard']
      graveyard ||= []

      result = graveyard.reverse
    end

    result
  end

  def getWaitingRoomInfo()
    logging("getWaitingRoomInfo start.")
    result = []

    save_data(@savefiles['characters']) do |saveData|
      waitingRoom = getWaitinigRoomFromSaveData(saveData)
      result = waitingRoom
    end

    result
  end

  def setWaitingRoomInfo(data)
    change_save_data(@savefiles['characters']) do |saveData|
      waitingRoom = getWaitinigRoomFromSaveData(saveData)
      waitingRoom.concat(data)
    end
  end

  def getImageList()
    logging("getImageList start.")

    imageList = getAllImageFileNameFromTagInfoFile()
    logging(imageList, "imageList all result")

    addTextsCharacterImageList(imageList, $imageUrlText)
    addLocalImageToList(imageList)

    deleteInvalidImageFileName(imageList)

    imageList.sort!

    imageList
  end

  def addTextsCharacterImageList(imageList, *texts)
    texts.each do |text|
      next unless (exist?(text))

      lines = readlines(text)
      lines.each do |line|
        line.chomp!

        next if (line.empty?)
        next if (imageList.include?(line))

        imageList << line
      end
    end
  end

  def addLocalImageToList(imageList)
    files = Dir.glob("#{$imageUploadDir}/*")

    files.each do |fileName|
      file = file.untaint #TODO:WHAT? このfileはどこから来たのか分からない

      next if (imageList.include?(fileName))
      next unless (isAllowedFileExt(fileName))

      imageList << fileName
      logging(fileName, "added local image")
    end
  end

  def deleteInvalidImageFileName(imageList)
    imageList.delete_if { |i| (/\.txt$/===i) }
    imageList.delete_if { |i| (/\.lock$/===i) }
    imageList.delete_if { |i| (/\.json$/===i) }
    imageList.delete_if { |i| (/\.json~$/===i) }
    imageList.delete_if { |i| (/^.svn$/===i) }
    imageList.delete_if { |i| (/.db$/===i) }
  end


  def sendDiceBotChatMessage
    logging('sendDiceBotChatMessage')

    params = getParamsFromRequestData()

    repeatCount = getDiceBotRepeatCount(params)

    message = params['message']

    results = []
    repeatCount.times do |i|
      oneMessage = message

      if repeatCount > 1
        oneMessage = message + " #" + (i + 1).to_s
      end

      logging(oneMessage, "sendDiceBotChatMessage oneMessage")
      result = sendDiceBotChatMessageOnece(params, oneMessage)
      logging(result, "sendDiceBotChatMessageOnece result")

      next if (result.nil?)
      results << result
    end

    logging(results, "sendDiceBotChatMessage results")

    results
  end

  def getDiceBotRepeatCount(params)
    repeatCountLimit = 20

    repeatCount = params['repeatCount']

    repeatCount ||= 1
    repeatCount = 1 if (repeatCount < 1)
    repeatCount = repeatCountLimit if (repeatCount > repeatCountLimit)

    repeatCount
  end

  def sendDiceBotChatMessageOnece(params, message)
    params = params.clone
    name = params['name']
    state = params['state']
    color = params['color']
    channel = params['channel']
    sendto = params['sendto']
    gameType = params['gameType']
    isNeedResult = params['isNeedResult']

    rollResult, isSecret, randResults = rollDice(message, gameType, isNeedResult)

    logging(rollResult, 'rollResult')
    logging(isSecret, 'isSecret')
    logging(randResults, "randResults")

    secretResult = ""
    if isSecret
      secretResult = message + rollResult
    else
      message = message + rollResult
    end

    message = getChatRolledMessage(message, isSecret, randResults, params)

    senderName = name
    senderName << ("\t" + state) unless (state.empty?)

    chatData = {
        "senderName" => senderName,
        "message" => message,
        "color" => color,
        "uniqueId" => '0',
        "channel" => channel
    }

    unless sendto.nil?
      chatData['sendto'] = sendto
    end

    logging(chatData, 'sendDiceBotChatMessage chatData')

    sendChatMessageByChatData(chatData)


    result = nil
    if isSecret
      params['isSecret'] = isSecret
      params['message'] = secretResult
      result = params
    end

    result
  end

  def rollDice(message, gameType, isNeedResult)
    logging(message, 'rollDice message')
    logging(gameType, 'rollDice gameType')

    require 'cgiDiceBot.rb'
    bot = CgiDiceBot.new
    dir = getDiceBotExtraTableDirName
    result, randResults = bot.roll(message, gameType, dir, @dicebot_table_prefix, isNeedResult)

    result.gsub!(/＞/, '→')
    result.sub!(/\r?\n?\Z/, '')

    logging(result, 'rollDice result')

    return result, bot.isSecret, randResults
  end

  def getDiceBotExtraTableDirName
    getRoomLocalSpaceDirName
  end


  def getChatRolledMessage(message, isSecret, randResults, params)
    logging("getChatRolledMessage Begin")
    logging(message, "message")
    logging(isSecret, "isSecret")
    logging(randResults, "randResults")

    if isSecret
      message = "シークレットダイス"
    end

    randResults = getRandResults(randResults, isSecret)

    if randResults.nil?
      logging("randResults is nil")
      return message
    end


    data = {
        "chatMessage" => message,
        "randResults" => randResults,
        "uniqueId" => params['uniqueId'],
    }

    text = "###CutInCommand:rollVisualDice###" + build_json(data)
    logging(text, "getChatRolledMessage End text")

    text
  end

  def getRandResults(randResults, isSecret)
    logging(randResults, 'getRandResults randResults')
    logging(isSecret, 'getRandResults isSecret')

    if isSecret
      randResults = randResults.collect { |value, max| [0, 0] }
    end

    logging(randResults, 'getRandResults result')

    randResults
  end


  def sendChatMessageAll
    logging("sendChatMessageAll Begin")

    result = {'result' => "NG"}

    return result if ($mentenanceModePassword.nil?)
    chatData = getParamsFromRequestData()

    password = chatData["password"]
    logging(password, "password check...")
    return result unless (password == $mentenanceModePassword)

    logging("adminPoassword check OK.")

    rooms = []

    $saveDataMaxCount.times do |roomNumber|
      logging(roomNumber, "loop roomNumber")

      init_savefiles(roomNumber)

      trueSaveFileName = @savedir_info.getTrueSaveFileName($playRoomInfo)
      next unless (exist?(trueSaveFileName))

      logging(roomNumber, "sendChatMessageAll to No.")
      sendChatMessageByChatData(chatData)

      rooms << roomNumber
    end

    result['result'] = "OK"
    result['rooms'] = rooms
    logging(result, "sendChatMessageAll End, result")

    result
  end

  def sendChatMessage
    chatData = getParamsFromRequestData()
    sendChatMessageByChatData(chatData)
  end

  def sendChatMessageByChatData(chatData)

    chatMessageData = nil

    change_save_data(@savefiles['chatMessageDataLog']) do |saveData|
      chatMessageDataLog = getChatMessageDataLog(saveData)

      deleteOldChatMessageData(chatMessageDataLog)

      now = Time.now.to_f
      chatMessageData = [now, chatData]

      chatMessageDataLog.push(chatMessageData)
      chatMessageDataLog.sort!

      logging(chatMessageDataLog, "chatMessageDataLog")
      logging(saveData['chatMessageDataLog'], "saveData['chatMessageDataLog']")
    end

    if $IS_SAVE_LONG_CHAT_LOG
      saveAllChatMessage(chatMessageData)
    end
  end

  def deleteOldChatMessageData(chatMessageDataLog)
    now = Time.now.to_f

    chatMessageDataLog.delete_if do |chatMessageData|
      writtenTime, chatMessage, *dummy = chatMessageData
      timeDiff = now - writtenTime

      (timeDiff > ($oldMessageTimeout))
    end
  end


  def deleteChatLog
    trueSaveFileName = @savefiles['chatMessageDataLog']
    deleteChatLogBySaveFile(trueSaveFileName)

    {'result' => "OK"}
  end

  def deleteChatLogBySaveFile(trueSaveFileName)
    change_save_data(trueSaveFileName) do |saveData|
      chatMessageDataLog = getChatMessageDataLog(saveData)
      chatMessageDataLog.clear
    end

    deleteChatLogAll()
  end

  def deleteChatLogAll()
    logging("deleteChatLogAll Begin")

    file = @savedir_info.getTrueSaveFileName($chatMessageDataLogAll)
    logging(file, "file")

    if File.exist?(file)
      locker = savefile_lock(file)
      locker.lock do
        File.delete(file)
      end
    end

    logging("deleteChatLogAll End")
  end


  def getChatMessageDataLog(saveData)
    getArrayInfoFromHash(saveData, 'chatMessageDataLog')
  end


  def saveAllChatMessage(chatMessageData)
    logging(chatMessageData, 'saveAllChatMessage chatMessageData')

    if chatMessageData.nil?
      return
    end

    saveFileName = @savedir_info.getTrueSaveFileName($chatMessageDataLogAll)

    locker = savefile_lock(saveFileName)
    locker.lock do

      lines = []
      if exist?(saveFileName)
        lines = readlines(saveFileName)
      end
      lines << build_json(chatMessageData)
      lines << "\n"

      while lines.size > $chatMessageDataLogAllLineMax
        lines.shift
      end

      create_file(saveFileName, lines.join())
    end

  end

  def changeMap()
    mapData = getParamsFromRequestData()
    logging(mapData, "mapData")

    changeMapSaveData(mapData)
  end

  def changeMapSaveData(mapData)
    logging("changeMap start.")

    change_save_data(@savefiles['map']) do |saveData|
      draws = getDraws(saveData)
      setMapData(saveData, mapData)
      draws.each { |i| setDraws(saveData, i) }
    end
  end


  def setMapData(saveData, mapData)
    saveData['mapData'] ||= {}
    saveData['mapData'] = mapData
  end

  def getMapData(saveData)
    saveData['mapData'] ||= {}
    saveData['mapData']
  end


  def drawOnMap
    logging('drawOnMap Begin')

    params = getParamsFromRequestData()
    data = params['data']
    logging(data, 'data')

    change_save_data(@savefiles['map']) do |saveData|
      setDraws(saveData, data)
    end

    logging('drawOnMap End')
  end

  def setDraws(saveData, data)
    return if (data.nil?)
    return if (data.empty?)

    info = data.first
    if info['imgId'].nil?
      info['imgId'] = createCharacterImgId('draw_')
    end

    draws = getDraws(saveData)
    draws << data
  end

  def getDraws(saveData)
    mapData = getMapData(saveData)
    mapData['draws'] ||= []
    mapData['draws']
  end

  def clearDrawOnMap
    change_save_data(@savefiles['map']) do |saveData|
      draws = getDraws(saveData)
      draws.clear
    end
  end

  def undoDrawOnMap
    result = {
        'data' => nil
    }

    change_save_data(@savefiles['map']) do |saveData|
      draws = getDraws(saveData)
      result['data'] = draws.pop
    end

    result
  end


  def addEffect()
    effectData = getParamsFromRequestData()
    effectDataList = [effectData]
    addEffectData(effectDataList)
  end

  def findEffect(effects, keys, data)
    found = nil

    effects.find do |effect|
      allMatched = true

      keys.each do |key|
        if effect[key] != data[key]
          allMatched = false
          break
        end
      end

      if allMatched
        found = effect
        break
      end
    end

    found
  end

  def addEffectData(effectDataList)
    change_save_data(@savefiles['effects']) do |saveData|
      saveData['effects'] ||= []
      effects = saveData['effects']

      effectDataList.each do |effectData|
        logging(effectData, "addEffectData target effectData")

        if effectData['type'] == 'standingGraphicInfos'
          keys = ['type', 'name', 'state']
          found = findEffect(effects, keys, effectData)

          if found
            logging(found, "addEffectData is already exist, found data is => ")
            next
          end
        end

        effectData['effectId'] = createCharacterImgId("effects_")
        effects << effectData
      end
    end
  end

  def changeEffect
    change_save_data(@savefiles['effects']) do |saveData|
      effectData = getParamsFromRequestData()
      targetCutInId = effectData['effectId']

      saveData['effects'] ||= []
      effects = saveData['effects']

      findIndex = -1
      effects.each_with_index do |i, index|
        if targetCutInId == i['effectId']
          findIndex = index
        end
      end

      if findIndex == -1
        return
      end

      effects[findIndex] = effectData
    end
  end

  def removeEffect()
    logging('removeEffect Begin')

    change_save_data(@savefiles['effects']) do |saveData|
      params = getParamsFromRequestData()
      effectId = params['effectId']
      logging(effectId, 'effectId')

      saveData['effects'] ||= []
      effects = saveData['effects']
      effects.delete_if { |i| (effectId == i['effectId']) }
    end

    logging('removeEffect End')
  end


  def getImageInfoFileName
    imageInfoFileName = fileJoin($imageUploadDir, 'imageInfo.json')

    logging(imageInfoFileName, 'imageInfoFileName')

    imageInfoFileName
  end

  def changeImageTags()
    effectData = getParamsFromRequestData()
    source = effectData['source']
    tagInfo = effectData['tagInfo']

    changeImageTagsLocal(source, tagInfo)
  end

  def getAllImageFileNameFromTagInfoFile()
    imageFileNames = []

    save_data(getImageInfoFileName()) do |saveData|
      imageTags = saveData['imageTags']
      imageTags ||= {}
      imageFileNames = imageTags.keys
    end

    imageFileNames
  end

  def changeImageTagsLocal(source, tagInfo)
    return if (tagInfo.nil?)

    change_save_data(getImageInfoFileName()) do |saveData|
      saveData['imageTags'] ||= {}
      imageTags = saveData['imageTags']

      imageTags[source] = tagInfo
    end
  end

  def deleteImageTags(source)

    change_save_data(getImageInfoFileName()) do |saveData|

      imageTags = saveData['imageTags']

      tagInfo = imageTags.delete(source)
      return false if (tagInfo.nil?)

      smallImage = tagInfo["smallImage"]
      begin
        deleteFile(smallImage)
      rescue => e
        errorMessage = getErrorResponseText(e)
        loggingException(e)
      end
    end

    true
  end

  def deleteFile(file)
    File.delete(file)
  end

  def getImageTagsAndImageList
    result = {}

    result['tagInfos'] = getImageTags()
    result['imageList'] = getImageList()
    result['imageDir'] = $imageUploadDir

    logging("getImageTagsAndImageList result", result)

    result
  end

  def getImageTags()
    logging('getImageTags start')
    imageTags = nil

    save_data(getImageInfoFileName()) do |saveData|
      imageTags = saveData['imageTags']
    end

    imageTags ||= {}
    logging(imageTags, 'getImageTags imageTags')

    imageTags
  end

  def createCharacterImgId(prefix = "character_")
    @imgIdIndex ||= 0
    @imgIdIndex += 1

    #return (prefix + Time.now.to_f.to_s + "_" + @imgIdIndex.to_s);
    (prefix + sprintf("%.4f_%04d", Time.now.to_f, @imgIdIndex))
  end


  def addCharacter()
    characterData = getParamsFromRequestData()
    characterDataList = [characterData]

    addCharacterData(characterDataList)
  end


  def isAlreadyExistCharacter?(characters, characterData)
    return false if (characterData['name'].nil?)
    return false if (characterData['name'].empty?)

    alreadyExist = characters.find do |i|
      (i['imgId'] == characterData['imgId']) or
          (i['name'] == characterData['name'])
    end

    return false if (alreadyExist.nil?)

    logging("target characterData is already exist. no creation.", "isAlreadyExistCharacter?")
    characterData['name']
  end

  def addCharacterData(characterDataList)
    result = {
        "addFailedCharacterNames" => []
    }

    change_save_data(@savefiles['characters']) do |saveData|
      saveData['characters'] ||= []
      characters = getCharactersFromSaveData(saveData)

      characterDataList.each do |characterData|
        logging(characterData, "characterData")

        characterData['imgId'] = createCharacterImgId()

        failedName = isAlreadyExistCharacterInRoom?(saveData, characterData)

        if failedName
          result["addFailedCharacterNames"] << failedName
          next
        end

        logging("add characterData to characters")
        characters << characterData
      end
    end

    result
  end

  def isAlreadyExistCharacterInRoom?(saveData, characterData)
    characters = getCharactersFromSaveData(saveData)
    waitingRoom = getWaitinigRoomFromSaveData(saveData)
    allCharacters = (characters + waitingRoom)

    failedName = isAlreadyExistCharacter?(allCharacters, characterData)
    failedName
  end


  def changeCharacter()
    characterData = getParamsFromRequestData()
    logging(characterData.inspect, "characterData")

    changeCharacterData(characterData)
  end

  def changeCharacterData(characterData)
    change_save_data(@savefiles['characters']) do |saveData|
      logging("changeCharacterData called")

      characters = getCharactersFromSaveData(saveData)

      index = nil
      characters.each_with_index do |item, targetIndex|
        if item['imgId'] == characterData['imgId']
          index = targetIndex
          break;
        end
      end

      if index.nil?
        logging("invalid character name")
        return
      end

      unless characterData['name'].nil? or characterData['name'].empty?
        alreadyExist = characters.find do |character|
          ((character['name'] == characterData['name']) and
              (character['imgId'] != characterData['imgId']))
        end

        if alreadyExist
          logging("same name character alread exist")
          return
        end
      end

      logging(characterData.inspect, "character data change")
      characters[index] = characterData
    end
  end

  def getCardType
    "Card"
  end

  def getCardMountType
    "CardMount"
  end

  def getRandomDungeonCardMountType
    "RandomDungeonCardMount"
  end

  def getCardTrushMountType
    "CardTrushMount"
  end

  def getRandomDungeonCardTrushMountType
    "RandomDungeonCardTrushMount"
  end

  def getRotation(isUpDown)
    rotation = 0

    if isUpDown && rand(2) == 0
        rotation = 180
    end

    rotation
  end

  def getCardData(isText, imageName, imageNameBack, mountName, isUpDown = false, canDelete = false)

    cardData = {
        "imageName" => imageName,
        "imageNameBack" => imageNameBack,
        "isBack" => true,
        "rotation" => getRotation(isUpDown),
        "isUpDown" => isUpDown,
        "isText" => isText,
        "isOpen" => false,
        "owner" => "",
        "ownerName" => "",
        "mountName" => mountName,
        "canDelete" => canDelete,

        "name" => "",
        "imgId" => createCharacterImgId(),
        "type" => getCardType(),
        "x" => 0,
        "y" => 0,
        "draggable" => true,
    }

    cardData
  end


  def addCardZone()
    logging("addCardZone Begin")

    data = getParamsFromRequestData()

    x = data['x']
    y = data['y']
    owner = data['owner']
    ownerName = data['ownerName']

    change_save_data(@savefiles['characters']) do |saveData|
      characters = getCharactersFromSaveData(saveData)
      logging(characters, "addCardZone characters")

      cardData = getCardZoneData(owner, ownerName, x, y)
      characters << cardData
    end

    logging("addCardZone End")
  end


  def initCards
    logging("initCards Begin")

    set_record_empty

    clearCharacterByTypeLocal(getCardType)
    clearCharacterByTypeLocal(getCardMountType)
    clearCharacterByTypeLocal(getRandomDungeonCardMountType)
    clearCharacterByTypeLocal(getCardZoneType)
    clearCharacterByTypeLocal(getCardTrushMountType)
    clearCharacterByTypeLocal(getRandomDungeonCardTrushMountType)


    params = getParamsFromRequestData()
    cardTypeInfos = params['cardTypeInfos']
    logging(cardTypeInfos, "cardTypeInfos")

    change_save_data(@savefiles['characters']) do |saveData|
      saveData['cardTrushMount'] = {}

      saveData['cardMount'] = {}
      cardMounts = saveData['cardMount']

      characters = getCharactersFromSaveData(saveData)
      logging(characters, "initCards saveData.characters")

      cardTypeInfos.each_with_index do |cardTypeInfo, index|
        mountName = cardTypeInfo['mountName']
        logging(mountName, "initCards mountName")

        cardsListFileName = cards_info.getCardFileName(mountName)
        logging(cardsListFileName, "initCards cardsListFileName")

        cardsList = []
        readlines(cardsListFileName).each_with_index do |i, lineIndex|
          cardsList << i.chomp.toutf8
        end

        logging(cardsList, "initCards cardsList")

        cardData = cardsList.shift.split(/,/)
        isText = (cardData.shift == "text")
        isUpDown = (cardData.shift == "upDown")
        logging("isUpDown", isUpDown)
        imageNameBack = cardsList.shift

        cardsList, isSorted = getInitCardSet(cardsList, cardTypeInfo)
        cardMounts[mountName] = getInitedCardMount(cardsList, mountName, isText, isUpDown, imageNameBack, isSorted)

        cardMountData = createCardMountData(cardMounts, isText, imageNameBack, mountName, index, isUpDown, cardTypeInfo, cardsList)
        characters << cardMountData

        cardTrushMountData = getCardTrushMountData(isText, mountName, index, cardTypeInfo)
        characters << cardTrushMountData
      end

      waitForRefresh = 0.2
      sleep(waitForRefresh)
    end

    logging("initCards End")

    cardExist = (not cardTypeInfos.empty?)
    {"result" => "OK", "cardExist" => cardExist}
  end


  def getInitedCardMount(cardsList, mountName, isText, isUpDown, imageNameBack, isSorted)
    cardMount = []

    cardsList.each do |imageName|
      if /^###Back###(.+)/ === imageName
        imageNameBack = $1
        next
      end

      logging(imageName, "initCards imageName")
      cardData = getCardData(isText, imageName, imageNameBack, mountName, isUpDown)
      cardMount << cardData
    end

    if isSorted
      cardMount = cardMount.reverse
    else
      cardMount = cardMount.sort_by { rand }
    end

    cardMount
  end


  def addCard()
    logging("addCard begin")

    addCardData = getParamsFromRequestData()

    isText = addCardData['isText']
    imageName = addCardData['imageName']
    imageNameBack = addCardData['imageNameBack']
    mountName = addCardData['mountName']
    isUpDown = addCardData['isUpDown']
    canDelete = addCardData['canDelete']
    isOpen = addCardData['isOpen']
    isBack = addCardData['isBack']

    change_save_data(@savefiles['characters']) do |saveData|
      cardData = getCardData(isText, imageName, imageNameBack, mountName, isUpDown, canDelete)
      cardData["x"] = addCardData['x']
      cardData["y"] = addCardData['y']
      cardData["isOpen"] = isOpen unless (isOpen.nil?)
      cardData["isBack"] = isBack unless (isBack.nil?)

      characters = getCharactersFromSaveData(saveData)
      characters << cardData
    end

    logging("addCard end")
  end

  #トランプのジョーカー枚数、使用デッキ数の指定
  def getInitCardSet(cardsList, cardTypeInfo)
    if (isRandomDungeonTrump(cardTypeInfo))
      cardsListTmp = getInitCardSetForRandomDungenTrump(cardsList, cardTypeInfo)
      return cardsListTmp, true
    end

    useLineCount = cardTypeInfo['useLineCount']
    useLineCount ||= cardsList.size
    logging(useLineCount, 'useLineCount')

    deckCount = cardTypeInfo['deckCount']
    deckCount ||= 1
    logging(deckCount, 'deckCount')

    cardsListTmp = []
    deckCount.to_i.times do
      cardsListTmp += cardsList[0...useLineCount]
    end

    return cardsListTmp, false
  end

  def getInitCardSetForRandomDungenTrump(cardList, cardTypeInfo)
    logging("getInitCardSetForRandomDungenTrump start")

    logging(cardList.length, "cardList.length")
    logging(cardTypeInfo, "cardTypeInfo")

    useCount = cardTypeInfo['cardCount']
    jorkerCount = cardTypeInfo['jorkerCount']

    useLineCount = 13 * 4 + jorkerCount
    cardList = cardList[0...useLineCount]
    logging(cardList.length, "cardList.length")

    aceList = []
    noAceList = []

    cardList.each_with_index do |card, index|
      if (index % 13) == 0 &&  aceList.length < 4
          aceList << card
          next
      end

      noAceList << card
    end

    logging(aceList, "aceList")
    logging(aceList.length, "aceList.length")
    logging(noAceList.length, "noAceList.length")

    cardTypeInfo['aceList'] = aceList.clone

    result = []

    aceList = aceList.sort_by { rand }
    result << aceList.shift
    logging(aceList, "aceList shifted")
    logging(result, "result")

    noAceList = noAceList.sort_by { rand }

    while result.length < useCount
      result << noAceList.shift
      break if (noAceList.length <= 0)
    end

    result = result.sort_by { rand }
    logging(result, "result.sorted")
    logging(noAceList, "noAceList is empty? please check")

    while aceList.length > 0
      result << aceList.shift
    end

    while noAceList.length > 0
      result << noAceList.shift
    end

    logging(result, "getInitCardSetForRandomDungenTrump end, result")

    result
  end


  def getCardZoneType
    "CardZone"
  end

  def getCardZoneData(owner, ownerName, x, y)
    # cardMount, isText, imageNameBack, mountName, index, isUpDown)
    isText = true
    cardText = ""
    cardMountData = getCardData(isText, cardText, cardText, "noneMountName")

    cardMountData['type'] = getCardZoneType
    cardMountData['owner'] = owner
    cardMountData['ownerName'] = ownerName
    cardMountData['x'] = x
    cardMountData['y'] = y

    cardMountData
  end


  def createCardMountData(cardMount, isText, imageNameBack, mountName, index, isUpDown, cardTypeInfo, cards)
    cardMountData = getCardData(isText, imageNameBack, imageNameBack, mountName)

    cardMountData['type'] = getCardMountType
    setCardCountAndBackImage(cardMountData, cardMount[mountName])
    cardMountData['mountName'] = mountName
    cardMountData['isUpDown'] = isUpDown
    cardMountData['x'] = getInitCardMountX(index)
    cardMountData['y'] = getInitCardMountY(0)

    unless cards.first.nil?
      cardMountData['nextCardId'] = cards.first['imgId']
    end

    if isRandomDungeonTrump(cardTypeInfo)
      cardCount = cardTypeInfo['cardCount']
      cardMountData['type'] = getRandomDungeonCardMountType
      cardMountData['cardCountDisplayDiff'] = cards.length - cardCount
      cardMountData['useCount'] = cardCount
      cardMountData['aceList'] = cardTypeInfo['aceList']
    end

    cardMountData
  end

  def getInitCardMountX(index)
    (50 + index * 150)
  end

  def getInitCardMountY(index)
    (50 + index * 200)
  end

  def isRandomDungeonTrump(cardTypeInfo)
    (cardTypeInfo['mountName'] == 'randomDungeonTrump')
  end

  def getCardTrushMountData(isText, mountName, index, cardTypeInfo)
    imageName, imageNameBack, isText = getCardTrushMountImageName(mountName)
    cardTrushMountData = getCardData(isText, imageName, imageNameBack, mountName)

    cardTrushMountData['type'] = getCardTrushMountTypeFromCardTypeInfo(cardTypeInfo)
    cardTrushMountData['cardCount'] = 0
    cardTrushMountData['mountName'] = mountName
    cardTrushMountData['x'] = getInitCardMountX(index)
    cardTrushMountData['y'] = getInitCardMountY(1)
    cardTrushMountData['isBack'] = false

    cardTrushMountData
  end

  def setTrushMountDataCardsInfo(saveData, cardMountData, cards)
    characters = getCharactersFromSaveData(saveData)
    mountName = cardMountData['mountName']

    imageName, imageNameBack, isText = getCardTrushMountImageName(mountName, cards)

    cardMountImageData = findCardMountDataByType(characters, mountName, getCardTrushMountType)
    return if (cardMountImageData.nil?)

    cardMountImageData['cardCount'] = cards.size
    cardMountImageData["imageName"] = imageName
    cardMountImageData["imageNameBack"] = imageName
    cardMountImageData["isText"] = isText
  end

  def getCardTrushMountImageName(mountName, cards = [])
    cardData = cards.last

    imageName = ""
    imageNameBack = ""
    isText = true

    if cardData.nil?
      cardTitle = cards_info.getCardTitleName(mountName)

      isText = true
      imageName = "<font size=\"40\">#{cardTitle}用<br>カード捨て場</font>"
      imageNameBack = imageName
    else
      isText = cardData["isText"]
      imageName = cardData["imageName"]
      imageNameBack = cardData["imageNameBack"]

      if cardData["owner"] == "nobody"
        imageName = imageNameBack
      end
    end

    return imageName, imageNameBack, isText
  end

  def getCardTrushMountTypeFromCardTypeInfo(cardTypeInfo)
    if isRandomDungeonTrump(cardTypeInfo)
      return getRandomDungeonCardTrushMountType
    end

    getCardTrushMountType
  end


  def returnCard
    logging("returnCard Begin")

    set_no_body_sender

    params = getParamsFromRequestData()

    mountName = params['mountName']
    logging(mountName, "mountName")

    change_save_data(@savefiles['characters']) do |saveData|

      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)

      cardData = trushCards.pop
      logging(cardData, "cardData")
      if cardData.nil?
        logging("returnCard trushCards is empty. END.")
        return
      end

      cardData['x'] = params['x'] + 150
      cardData['y'] = params['y'] + 10
      logging('returned cardData', cardData)

      characters = getCharactersFromSaveData(saveData)
      characters.push(cardData)

      trushMountData = findCardData(characters, params['imgId'])
      logging(trushMountData, "returnCard trushMountData")

      return if (trushMountData.nil?)

      setTrushMountDataCardsInfo(saveData, trushMountData, trushCards)
    end

    logging("returnCard End")
  end

  def drawCard
    logging("drawCard Begin")

    set_no_body_sender

    params = getParamsFromRequestData()
    logging(params, 'params')

    result = {
        "result" => "NG"
    }

    change_save_data(@savefiles['characters']) do |saveData|
      count = params['count']

      count.times do
        drawCardDataOne(params, saveData)
      end

      result["result"] = "OK"
    end

    logging("drawCard End")

    result
  end

  def drawCardDataOne(params, saveData)
    cardMount = getCardMountFromSaveData(saveData)

    mountName = params['mountName']
    cards = getCardsFromCardMount(cardMount, mountName)

    cardMountData = findCardMountData(saveData, params['imgId'])
    return if (cardMountData.nil?)

    cardCountDisplayDiff = cardMountData['cardCountDisplayDiff']
    unless cardCountDisplayDiff.nil?
      return if (cardCountDisplayDiff >= cards.length)
    end

    cardData = cards.pop
    return if (cardData.nil?)

    cardData['x'] = params['x']
    cardData['y'] = params['y']

    isOpen = params['isOpen']
    cardData['isOpen'] = isOpen
    cardData['isBack'] = false
    cardData['owner'] = params['owner']
    cardData['ownerName'] = params['ownerName']

    characters = getCharactersFromSaveData(saveData)
    characters << cardData

    logging(cards.size, 'cardMount[mountName].size')
    setCardCountAndBackImage(cardMountData, cards)
  end


  def drawTargetTrushCard
    logging("drawTargetTrushCard Begin")

    set_no_body_sender

    params = getParamsFromRequestData()

    mountName = params['mountName']
    logging(mountName, "mountName")

    change_save_data(@savefiles['characters']) do |saveData|

      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)

      cardData = removeFromArray(trushCards) { |i| i['imgId'] === params['targetCardId'] }
      logging(cardData, "cardData")
      return if (cardData.nil?)

      cardData['x'] = params['x']
      cardData['y'] = params['y']

      characters = getCharactersFromSaveData(saveData)
      characters.push(cardData)

      trushMountData = findCardData(characters, params['mountId'])
      logging(trushMountData, "returnCard trushMountData")

      return if (trushMountData.nil?)

      setTrushMountDataCardsInfo(saveData, trushMountData, trushCards)
    end

    logging("drawTargetTrushCard End")

    return {"result" => "OK"}
  end

  def drawTargetCard
    logging("drawTargetCard Begin")

    set_no_body_sender

    params = getParamsFromRequestData()
    logging(params, 'params')

    mountName = params['mountName']
    logging(mountName, 'mountName')

    change_save_data(@savefiles['characters']) do |saveData|
      cardMount = getCardMountFromSaveData(saveData)
      cards = getCardsFromCardMount(cardMount, mountName)
      cardData = cards.find { |i| i['imgId'] === params['targetCardId'] }

      if cardData.nil?
        logging(params['targetCardId'], "not found params['targetCardId']")
        return
      end

      cards.delete(cardData)

      cardData['x'] = params['x']
      cardData['y'] = params['y']

      cardData['isOpen'] = false
      cardData['isBack'] = false
      cardData['owner'] = params['owner']
      cardData['ownerName'] = params['ownerName']

      saveData['characters'] ||= []
      characters = getCharactersFromSaveData(saveData)
      characters << cardData

      cardMountData = findCardMountData(saveData, params['mountId'])
      if cardMountData.nil?
        logging(params['mountId'], "not found params['mountId']")
        return
      end

      logging(cards.size, 'cardMount[mountName].size')
      setCardCountAndBackImage(cardMountData, cards)
    end

    logging("drawTargetCard End")

    {"result" => "OK"}
  end

  def findCardMountData(saveData, mountId)
    characters = getCharactersFromSaveData(saveData)
    cardMountData = characters.find { |i| i['imgId'] === mountId }

    cardMountData
  end


  def setCardCountAndBackImage(cardMountData, cards)
    cardMountData['cardCount'] = cards.size

    card = cards.last
    return if (card.nil?)

    image = card["imageNameBack"]
    return if (image.nil?)

    cardMountData["imageNameBack"] = image
  end

  def dumpTrushCards()
    logging("dumpTrushCards Begin")

    set_no_body_sender

    dumpTrushCardsData = getParamsFromRequestData()
    logging(dumpTrushCardsData, 'dumpTrushCardsData')

    mountName = dumpTrushCardsData['mountName']
    logging(mountName, 'mountName')

    change_save_data(@savefiles['characters']) do |saveData|

      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)

      characters = getCharactersFromSaveData(saveData)

      dumpedCardId = dumpTrushCardsData['dumpedCardId']
      logging(dumpedCardId, "dumpedCardId")

      logging(characters.size, "characters.size before")
      cardData = deleteFindOne(characters) { |i| i['imgId'] === dumpedCardId }
      trushCards << cardData
      logging(characters.size, "characters.size after")

      trushMountData = characters.find { |i| i['imgId'] === dumpTrushCardsData['trushMountId'] }
      if trushMountData.nil?
        return
      end

      logging(trushMount, 'trushMount')
      logging(mountName, 'mountName')
      logging(trushMount[mountName], 'trushMount[mountName]')
      logging(trushMount[mountName].size, 'trushMount[mountName].size')

      setTrushMountDataCardsInfo(saveData, trushMountData, trushCards)
    end

    logging("dumpTrushCards End")
  end

  def deleteFindOne(array)
    findIndex = nil
    array.each_with_index do |i, index|
      if yield(i)
        findIndex = index
      end
    end

    if findIndex.nil?
      throw Exception.new("deleteFindOne target is NOT found inspect:") #+ array.inspect)
    end

    logging(array.size, "array.size before")
    item = array.delete_at(findIndex)
    logging(array.size, "array.size before")

    item
  end

  def shuffleCards
    logging("shuffleCard Begin")

    set_record_empty

    params = getParamsFromRequestData()
    mountName = params['mountName']
    trushMountId = params['mountId']
    isShuffle = params['isShuffle']

    logging(mountName, 'mountName')
    logging(trushMountId, 'trushMountId')

    change_save_data(@savefiles['characters']) do |saveData|

      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)

      cardMount = getCardMountFromSaveData(saveData)
      mountCards = getCardsFromCardMount(cardMount, mountName)

      while trushCards.size > 0
        cardData = trushCards.pop
        initTrushCardForReturnMount(cardData)
        mountCards << cardData
      end

      characters = getCharactersFromSaveData(saveData)

      trushMountData = findCardData(characters, trushMountId)
      return if (trushMountData.nil?)
      setTrushMountDataCardsInfo(saveData, trushMountData, trushCards)

      cardMountData = findCardMountDataByType(characters, mountName, getCardMountType)
      return if (cardMountData.nil?)

      if isShuffle
        isUpDown = cardMountData['isUpDown']
        mountCards = getShuffledMount(mountCards, isUpDown)
      end

      cardMount[mountName] = mountCards
      saveData['cardMount'] = cardMount

      setCardCountAndBackImage(cardMountData, mountCards)
    end

    logging("shuffleCard End")
  end


  def shuffleForNextRandomDungeon
    logging("shuffleForNextRandomDungeon Begin")

    set_record_empty

    params = getParamsFromRequestData()
    mountName = params['mountName']
    trushMountId = params['mountId']

    logging(mountName, 'mountName')
    logging(trushMountId, 'trushMountId')

    change_save_data(@savefiles['characters']) do |saveData|

      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)
      logging(trushCards.length, "trushCards.length")

      saveData['cardMount'] ||= {}
      cardMount = saveData['cardMount']
      cardMount[mountName] ||= []
      mountCards = cardMount[mountName]

      characters = getCharactersFromSaveData(saveData)
      cardMountData = findCardMountDataByType(characters, mountName, getRandomDungeonCardMountType)
      return if (cardMountData.nil?)

      aceList = cardMountData['aceList']
      logging(aceList, "aceList")

      aceCards = []
      aceCards += deleteAceFromCards(trushCards, aceList)
      aceCards += deleteAceFromCards(mountCards, aceList)
      aceCards += deleteAceFromCards(characters, aceList)
      aceCards = aceCards.sort_by { rand }

      logging(aceCards, "aceCards")
      logging(trushCards.length, "trushCards.length")
      logging(mountCards.length, "mountCards.length")

      useCount = cardMountData['useCount']
      if (mountCards.size + 1) < useCount
        useCount = (mountCards.size + 1)
      end

      mountCards = mountCards.sort_by { rand }

      insertPoint = rand(useCount)
      logging(insertPoint, "insertPoint")
      mountCards[insertPoint, 0] = aceCards.shift

      while aceCards.length > 0
        mountCards[useCount, 0] = aceCards.shift
        logging(useCount, "useCount")
      end

      mountCards = mountCards.reverse

      cardMount[mountName] = mountCards
      saveData['cardMount'] = cardMount

      newDiff = mountCards.size - useCount
      newDiff = 3 if (newDiff < 3)
      logging(newDiff, "newDiff")
      cardMountData['cardCountDisplayDiff'] = newDiff


      trushMountData = findCardData(characters, trushMountId)
      return if (trushMountData.nil?)
      setTrushMountDataCardsInfo(saveData, trushMountData, trushCards)

      setCardCountAndBackImage(cardMountData, mountCards)
    end

    logging("shuffleForNextRandomDungeon End")
  end

  def deleteAceFromCards(cards, aceList)
    result = cards.select { |i| aceList.include?(i['imageName']) }
    cards.delete_if { |i| aceList.include?(i['imageName']) }

    result
  end

  def findCardData(characters, cardId)
    cardData = characters.find { |i| i['imgId'] === cardId }
    cardData
  end

  def findCardMountDataByType(characters, mountName, cardMountType)
    cardMountData = characters.find do |i|
      ((i['type'] === cardMountType) && (i['mountName'] == mountName))
    end

    cardMountData
  end

  def getShuffledMount(mountCards, isUpDown)
    mountCards = mountCards.sort_by { rand }
    mountCards.each do |i|
      i["rotation"] = getRotation(isUpDown)
    end

    mountCards
  end

  def initTrushCardForReturnMount(cardData)
    cardData['isOpen'] = false
    cardData['isBack'] = true
    cardData['owner'] = ""
    cardData['ownerName'] = ""
  end


  def findTrushMountAndTrushCards(saveData, mountName)
    saveData['cardTrushMount'] ||= {}
    trushMount = saveData['cardTrushMount']

    trushMount[mountName] ||= []
    trushCards = trushMount[mountName]

    return trushMount, trushCards
  end

  def getMountCardInfos
    params = getParamsFromRequestData()
    logging(params, 'getTrushMountCardInfos params')

    mountName = params['mountName']
    mountId = params['mountId']

    cards = []

    change_save_data(@savefiles['characters']) do |saveData|
      cardMount = getCardMountFromSaveData(saveData)
      cards = getCardsFromCardMount(cardMount, mountName)

      cardMountData = findCardMountData(saveData, mountId)
      cardCountDisplayDiff = cardMountData['cardCountDisplayDiff']

      logging(cardCountDisplayDiff, "cardCountDisplayDiff")
      logging(cards.length, "before cards.length")

      unless cardCountDisplayDiff.nil?
        unless cards.empty?
          cards = cards[cardCountDisplayDiff .. -1]
        end
      end

    end

    logging(cards.length, "getMountCardInfos cards.length")

    cards
  end

  def getTrushMountCardInfos
    params = getParamsFromRequestData()
    logging(params, 'getTrushMountCardInfos params')

    mountName = params['mountName']
    mountId = params['mountId']

    cards = []

    change_save_data(@savefiles['characters']) do |saveData|
      trushMount, trushCards = findTrushMountAndTrushCards(saveData, mountName)
      cards = trushCards
    end

    cards
  end


  def clearCharacterByType()
    logging("clearCharacterByType Begin")

    set_record_empty

    clearData = getParamsFromRequestData()
    logging(clearData, 'clearData')

    targetTypes = clearData['types']
    logging(targetTypes, 'targetTypes')

    targetTypes.each do |targetType|
      clearCharacterByTypeLocal(targetType)
    end

    logging("clearCharacterByType End")
  end

  def clearCharacterByTypeLocal(targetType)
    logging(targetType, "clearCharacterByTypeLocal targetType")

    change_save_data(@savefiles['characters']) do |saveData|
      characters = getCharactersFromSaveData(saveData)

      characters.delete_if do |i|
        (i['type'] == targetType)
      end
    end

    logging("clearCharacterByTypeLocal End")
  end


  def removeCharacter()
    removeCharacterDataList = getParamsFromRequestData()
    removeCharacterByRemoveCharacterDataList(removeCharacterDataList)
  end


  def removeCharacterByRemoveCharacterDataList(removeCharacterDataList)
    logging(removeCharacterDataList, "removeCharacterDataList")

    change_save_data(@savefiles['characters']) do |saveData|
      characters = getCharactersFromSaveData(saveData)

      removeCharacterDataList.each do |removeCharacterData|
        logging(removeCharacterData, "removeCharacterData")

        removeCharacterId = removeCharacterData['imgId']
        logging(removeCharacterId, "removeCharacterId")
        isGotoGraveyard = removeCharacterData['isGotoGraveyard']
        logging(isGotoGraveyard, "isGotoGraveyard")

        characters.delete_if do |i|
          deleted = (i['imgId'] == removeCharacterId)

          if (deleted and isGotoGraveyard)
            moveCharacterToGraveyard(i, saveData)
          end

          deleted
        end
      end

      logging(characters, "character deleted result")
    end
  end

  def moveCharacterToGraveyard(character, saveData)
    saveData['graveyard'] ||= []
    graveyard = saveData['graveyard']

    graveyard << character

    while graveyard.size > $graveyardLimit
      graveyard.shift
    end
  end


  def enterWaitingRoomCharacter

    set_record_empty

    params = getParamsFromRequestData()
    characterId = params['characterId']

    logging(characterId, "enterWaitingRoomCharacter characterId")

    result = {"result" => "NG"}
    change_save_data(@savefiles['characters']) do |saveData|
      characters = getCharactersFromSaveData(saveData)

      enterCharacterData = removeFromArray(characters) { |i| (i['imgId'] == characterId) }
      return result if (enterCharacterData.nil?)

      waitingRoom = getWaitinigRoomFromSaveData(saveData)
      waitingRoom << enterCharacterData
    end

    result["result"] = "OK"
    result
  end


  def resurrectCharacter
    params = getParamsFromRequestData()
    resurrectCharacterId = params['imgId']
    logging(resurrectCharacterId, "resurrectCharacterId")

    change_save_data(@savefiles['characters']) do |saveData|
      graveyard = getGraveyardFromSaveData(saveData)

      characterData = removeFromArray(graveyard) do |character|
        character['imgId'] == resurrectCharacterId
      end

      logging(characterData, "resurrectCharacter CharacterData")
      return if (characterData.nil?)

      characters = getCharactersFromSaveData(saveData)
      characters << characterData
    end

    nil
  end

  def clearGraveyard
    logging("clearGraveyard begin")

    change_save_data(@savefiles['characters']) do |saveData|
      graveyard = getGraveyardFromSaveData(saveData)
      graveyard.clear
    end

    nil
  end


  def getGraveyardFromSaveData(saveData)
    getArrayInfoFromHash(saveData, 'graveyard')
  end

  def getWaitinigRoomFromSaveData(saveData)
    getArrayInfoFromHash(saveData, 'waitingRoom')
  end

  def getCharactersFromSaveData(saveData)
    getArrayInfoFromHash(saveData, 'characters')
  end

  def getCardsFromCardMount(cardMount, mountName)
    getArrayInfoFromHash(cardMount, mountName)
  end

  def getArrayInfoFromHash(hash, key)
    hash[key] ||= []
    hash[key]
  end

  def getCardMountFromSaveData(saveData)
    getHashInfoFromHash(saveData, 'cardMount')
  end

  def getHashInfoFromHash(hash, key)
    hash[key] ||= {}
    hash[key]
  end


  def exitWaitingRoomCharacter

    set_record_empty

    params = getParamsFromRequestData()
    targetCharacterId = params['characterId']
    x = params['x']
    y = params['y']
    logging(targetCharacterId, 'exitWaitingRoomCharacter targetCharacterId')

    result = {"result" => "NG"}
    change_save_data(@savefiles['characters']) do |saveData|
      waitingRoom = getWaitinigRoomFromSaveData(saveData)

      characterData = removeFromArray(waitingRoom) do |character|
        character['imgId'] == targetCharacterId
      end

      logging(characterData, "exitWaitingRoomCharacter CharacterData")
      return result if (characterData.nil?)

      characterData['x'] = x
      characterData['y'] = y

      characters = getCharactersFromSaveData(saveData)
      characters << characterData
    end

    result["result"] = "OK"
    result
  end


  def removeFromArray(array)
    index = nil
    array.each_with_index do |i, targetIndex|
      logging(i, "i")
      logging(targetIndex, "targetIndex")
      b = yield(i)
      logging(b, "yield(i)")
      if b
        index = targetIndex
      end
    end

    return nil if (index.nil?)

    array.delete_at(index)
  end


  def changeRoundTime
    roundTimeData = getParamsFromRequestData()
    changeInitiativeData(roundTimeData)
  end

  def changeInitiativeData(roundTimeData)
    change_save_data(@savefiles['time']) do |saveData|
      saveData['roundTimeData'] = roundTimeData
    end
  end


  def moveCharacter()
    change_save_data(@savefiles['characters']) do |saveData|

      characterMoveData = getParamsFromRequestData()
      logging(characterMoveData, "moveCharacter() characterMoveData")

      logging(characterMoveData['imgId'], "character.imgId")

      characters = getCharactersFromSaveData(saveData)

      characters.each do |characterData|
        next unless (characterData['imgId'] == characterMoveData['imgId'])

        characterData['x'] = characterMoveData['x']
        characterData['y'] = characterMoveData['y']

        break
      end

      logging(characters, "after moved characters")

    end
  end

  #override
  def getSaveFileTimeStamp(saveFileName)
    unless exist?(saveFileName)
      return 0
    end

    timeStamp = File.mtime(saveFileName).to_f
  end

  def getSaveFileTimeStampMillSecond(saveFileName)
    (getSaveFileTimeStamp(saveFileName) * 1000).to_i
  end

  def isSaveFileChanged(lastUpdateTime, saveFileName)
    lastUpdateTime = lastUpdateTime.to_i
    saveFileTimeStamp = getSaveFileTimeStampMillSecond(saveFileName)
    changed = (saveFileTimeStamp != lastUpdateTime)

    logging(saveFileName, "saveFileName")
    logging(saveFileTimeStamp.inspect, "saveFileTimeStamp")
    logging(lastUpdateTime.inspect, "lastUpdateTime   ")
    logging(changed, "changed")

    changed
  end

  def getResponse
    response = analyze_command

    if isJsonResult
      build_json(response)
    else
      build_msgpack(response)
    end
  end
end


def getErrorResponseText(e)
  errorMessage = ""
  errorMessage << "e.to_s : " << e.to_s << "\n"
  errorMessage << "e.inspect : " << e.inspect << "\n"
  errorMessage << "$@ : " << $@.join("\n") << "\n"
  errorMessage << "$! : " << $!.to_s << "\n"

  errorMessage
end


def isGzipTarget(result, server)
  return false if ($gzipTargetSize <= 0)
  return false if (server.jsonp_callback)

  ((/gzip/ =~ ENV["HTTP_ACCEPT_ENCODING"]) and (result.length > $gzipTargetSize))
end

def getGzipResult(result)
  require 'zlib'
  require 'stringio'

  stringIo = StringIO.new
  Zlib::GzipWriter.wrap(stringIo) do |gz|
    gz.write(result)
    gz.flush
    gz.finish
  end

  gzipResult = stringIo.string
  logging(gzipResult.length.to_s, "CGI response zipped length  ")

  gzipResult
end


def main(cgiParams)
  logging("main called")
  server = DodontoFServer.new(SaveDirInfo.new(), cgiParams)
  logging("server created")
  printResult(server)
  logging("printResult called")
end

def getInitializedHeaderText(server)
  header = ""

  if $isModRuby
    #Apache::request.content_type = "text/plain; charset=utf-8"
    #Apache::request.send_header
  else
    if server.is_json_result
      header = "Content-Type: text/plain; charset=utf-8\n"
    else
      header = "Content-Type: application/x-msgpack; charset=x-user-defined\n"
    end
  end

  header
end

def printResult(server)
  logging("========================================>CGI begin.")

  text = "empty"

  header = getInitializedHeaderText(server)

  begin
    result = server.getResponse

    if server.is_add_marker
      result = "#D@EM>#" + result + "#<D@EM#"
    end

    if server.jsonp_callback
      result = "#{server.jsonpCallBack}(" + result + ");"
    end

    logging(result.length.to_s, "CGI response original length")

    if isGzipTarget(result, server)
      if $isModRuby
        Apache.request.content_encoding = 'gzip'
      else
        header << "Content-Encoding: gzip\n"

        if server.jsonpCallBack
          header << "Access-Control-Allow-Origin: *\n"
        end
      end

      text = getGzipResult(result)
    else
      text = result
    end
  rescue Exception => e
    errorMessage = getErrorResponseText(e)
    loggingForce(errorMessage, "errorMessage")

    text = "\n= ERROR ====================\n"
    text << errorMessage
    text << "============================\n"
  end

  logging(header, "RESPONSE header")

  output = $stdout
  output.binmode if (defined?(output.binmode))

  output.print(header + "\n")

  output.print(text)

  logging("========================================>CGI end.")
end


def getCgiParams()
  logging("getCgiParams Begin")

  length = ENV['CONTENT_LENGTH'].to_i
  logging(length, "getCgiParams length")

  input = nil
  if ENV['REQUEST_METHOD'] == "POST"
    input = $stdin.read(length)
  else
    input = ENV['QUERY_STRING']
  end

  logging(input, "getCgiParams input")
  messagePackedData = DodontoFServer.parse_msgpack(input)

  logging(messagePackedData, "messagePackedData")
  logging("getCgiParams End")

  messagePackedData
end


def executeDodontoServerCgi()
  initLog()

  cgiParams = getCgiParams()

  case $dbType
    when "mysql"
      #mod_ruby でも再読み込みするようにloadに
      require 'DodontoFServerMySql.rb'
      mainMySql(cgiParams)
    else
      #通常のテキストファイル形式
      main(cgiParams)
  end

end

if $0 === __FILE__
  executeDodontoServerCgi()
end
