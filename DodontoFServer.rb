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
      @savefiles[saveDataKeyName] = @savedir_info.real_savefile_name(saveFileName)
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
    savefile_name = @savedir_info.real_savefile_name($chatMessageDataLogAll)
    lockfile = savefile_lock_readonly(savefile_name)

    lines = []
    lockfile.lock do
      if exist?(savefile_name)
        lines = readlines(savefile_name)
      end

      @last_update_times[type_name] = savefile_timestamp_millisec(savefile_name)
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
      logging_exception(e)
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

    character_update_time = savefile_timestamp_millisec(file_name)

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

    real_savefile_name = @savedir_info.real_savefile_name($record)
    save_data = load_default_savefile($recordKey, real_savefile_name)
    @record = record_by_save_data(save_data)
  end

  def load_default_savefile(type_name, file_name)
    lockfile = savefile_lock_readonly(file_name)

    text_data = ""
    lockfile.lock do
      @last_update_times[type_name] = savefile_timestamp_millisec(file_name)
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

    real_savefile_name = @savedir_info.real_savefile_name($record)
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
      logging_exception(e)
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
      logging_exception(e)
    rescue Exception => e
      loggingForce("getMessagePackFromData Exception rescue")
      logging_exception(e)
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
        return busy_info
      when 'getServerInfo'
        return server_info_for_webif
      when 'getRoomList'
        logging("getRoomList passed")
        return room_list_for_webif
      else

    end

    login_on_web_interface

    case current_command
      when 'chat'
        return chat_text_for_webif
      when 'talk'
        return send_chat_text_for_webif
      when 'addCharacter'
        return send_add_character_for_webif
      when 'changeCharacter'
        return change_character_for_webif
      when 'addMemo'
        return send_memo_for_webif
      when 'getRoomInfo'
        return room_info_for_webif
      when 'setRoomInfo'
        return set_room_info_for_webif
      when 'getChatColor'
        return chat_color
      when 'refresh'
        return refresh_for_webif
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

    checked_result = check_login_password(room_index, password, visitor_mode)
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

      if savefile_changed?(target_last_update_time, file_name)
        logging(file_name, "saveFile is changed")
        save_data = load_savefile(type_name, file_name)
        yield(save_data, type_name)
      end
    end
  end


  def chat_text_for_webif
    logging("getWebIfChatText begin")

    time= request_number_for_webif('time', -1)
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
    refresh_routine(save_data)

    exclude_old_chat_for_webif(time, save_data)

    logging(save_data, 'getWebIfChatTextFromTime saveData')

    save_data
  end


  def chat_text_by_second(seconds)
    logging(seconds, 'getWebIfChatTextFromSecond seconds')

    time = target_range_chat_time(seconds)
    logging(seconds, "seconds")
    logging(time, "time")

    save_data = {}
    @last_update_times = {'chatMessageDataLog' => time}
    current_save_data() do |targetSaveData, saveFileTypeName|
      save_data.merge!(targetSaveData)
    end

    exclude_old_chat_for_webif(time, save_data)

    logging("getCurrentSaveData end saveData", save_data)

    save_data
  end

  def exclude_old_chat_for_webif(time, save_data)
    logging(time, 'deleteOldChatTextForWebIf time')

    return if (time.nil?)

    chats = save_data['chatMessageDataLog']
    return if (chats.nil?)

    chats.delete_if do |writtenTime, data|
      ((writtenTime < time) or (not data['sendto'].nil?))
    end

    logging('deleteOldChatTextForWebIf End')
  end


  def target_range_chat_time(seconds)
    case seconds
      when "all"
        return 0
      when nil
        return Time.now.to_i - $oldMessageTimeout
      else
    end

    Time.now.to_i - seconds.to_i
  end


  def chat_color()
    name = request_text_for_webif('name')
    logging(name, "name")
    if invalid_param?(name)
      raise "対象ユーザー名(name)を指定してください"
    end

    color = chat_color_in_save_data(name)
    # color ||= getTalkDefaultColor
    if color.nil?
      raise "指定ユーザー名の発言が見つかりません"
    end

    result = {}
    result['result'] = 'OK'
    result['color'] = color

    result
  end

  def chat_color_in_save_data(name)
    seconds = 'all'
    save_data = chat_text_by_second(seconds)

    chats = save_data['chatMessageDataLog']
    chats.reverse_each do |time, data|
      sender_name = data['senderName'].split(/\t/).first
      if name == sender_name
        return data['color']
      end
    end

    nil
  end

  def default_color
    "000000"
  end

  def busy_info()
    json_data = {
        "loginCount" => File.readlines($loginCountFile).join.to_i,
        "maxLoginCount" => $aboutMaxLoginCount,
        "version" => $version,
        "result" => 'OK',
    }
  end

  def server_info_for_webif()
    result_data = {
        "max_room" => ($saveDataMaxCount - 1),
        'isNeedCreatePassword' => (not $createPlayRoomPassword.empty?),
        'result' => 'OK',
    }

    if request_boolean_for_webif("card", false)
      cards_infos = cards_info.collectCardTypeAndTypeName()
      result_data["cardInfos"] = cards_infos
    end

    if request_boolean_for_webif("dice", false)
      require 'diceBotInfos'
      dicebot_infos = DiceBotInfos.new.getInfos
      result_data['diceBotInfos'] = dicebot_infos()
    end

    result_data
  end

  def room_list_for_webif()
    logging("getWebIfRoomList Begin")
    min_room = request_int_for_webif('min_room', 0)
    max_room = request_int_for_webif('max_room', ($saveDataMaxCount - 1))

    room_states = play_room_states_local(min_room, max_room)

    result_data = {
        "playRoomStates" => room_states,
        "result" => 'OK',
    }

    logging("getWebIfRoomList End")
    result_data
  end

  def send_chat_text_for_webif
    logging("sendWebIfChatText begin")
    save_data = {}

    name = request_text_for_webif('name')
    logging(name, "name")

    message = request_text_for_webif('message')
    message.gsub!(/\r\n/, "\r")
    logging(message, "message")

    color = request_text_for_webif('color', default_color)
    logging(color, "color")

    channel = request_int_for_webif('channel')
    logging(channel, "channel")

    game_type = request_text_for_webif('bot')
    logging(game_type, 'gameType')

    roll_result, is_secret, rand_results = rollDice(message, game_type, false)

    message = message + roll_result
    logging(message, "diceRolled message")

    chat_data = {
        "senderName" => name,
        "message" => message,
        "color" => color,
        "uniqueId" => '0',
        "channel" => channel,
    }
    logging("sendWebIfChatText chatData", chat_data)

    sendChatMessageByChatData(chat_data)

    result = {}
    result['result'] = 'OK'
    result
  end

  def request_text_for_webif(key, default = '')
    text = request_data(key)

    if text.nil? or text.empty?
      text = default
    end

    text
  end

  def request_int_for_webif(key, default = 0)
    text = request_text_for_webif(key, default.to_s)
    text.to_i
  end

  def request_number_for_webif(key, default = 0)
    text = request_text_for_webif(key, default.to_s)
    text.to_f
  end

  def request_boolean_for_webif(key, default = false)
    text = request_text_for_webif(key)
    if text.empty?
      return default
    end

    (text == "true")
  end

  def request_array_for_webif(key, empty = [], separator = ',')
    text = request_text_for_webif(key, nil)

    if text.nil?
      return empty
    end

    text.split(separator)
  end

  def request_hash_for_webif(key, default = {}, separator1 = ':', separator2 = ',')
    logging("getWebIfRequestHash begin")
    logging(key, "key")
    logging(separator1, "separator1")
    logging(separator2, "separator2")

    array = request_array_for_webif(key, [], separator2)
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

  def send_memo_for_webif
    logging('sendWebIfAddMemo begin')

    result = {}
    result['result'] = 'OK'

  result_context = {
        "message" => request_text_for_webif('message', ''),
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

    logging(result_context, 'sendWebIfAddMemo jsonData')
    addResult = addCharacterData([result_context]) #TODO:WAHT? addResultはここで始めて宣言されているように見える

    result
  end


  def send_add_character_for_webif
    logging("sendWebIfAddCharacter begin")

    result = {}
    result['result'] = 'OK'

    character_data = {
        "name" => request_text_for_webif('name'),
        "size" => request_int_for_webif('size', 1),
        "x" => request_int_for_webif('x', 0),
        "y" => request_int_for_webif('y', 0),
        "initiative" => request_number_for_webif('initiative', 0),
        "counters" => request_hash_for_webif('counters'),
        "info" => request_text_for_webif('info'),
        "imageName" => image_name_for_webif('image', ".\/image\/defaultImageSet\/pawn\/pawnBlack.png"),
        "rotation" => request_int_for_webif('rotation', 0),
        "statusAlias" => request_hash_for_webif('statusAlias'),
        "dogTag" => request_text_for_webif('dogTag', ""),
        "draggable" => request_boolean_for_webif("draggable", true),
        "isHide" => request_boolean_for_webif("isHide", false),
        "type" => "characterData",
        "imgId" => createCharacterImgId(),
    }

    logging(character_data, 'sendWebIfAddCharacter jsonData')


    if character_data['name'].empty?
      result['result'] = "キャラクターの追加に失敗しました。キャラクター名が設定されていません"
      return result
    end


    add_result = addCharacterData([character_data])
    add_failed_char_names = add_result["addFailedCharacterNames"]
    logging(add_failed_char_names, 'addFailedCharacterNames')

    if add_failed_char_names.length > 0
      result['result'] = "キャラクターの追加に失敗しました。同じ名前のキャラクターがすでに存在しないか確認してください。\"#{add_failed_char_names.join(' ')}\""
    end

    result
  end

  def image_name_for_webif(key, default)
    logging("getWebIfImageName begin")
    logging(key, "key")
    logging(default, "default")

    image = request_text_for_webif(key, default)
    logging(image, "image")

    if image != default
      image.gsub!('(local)', $imageUploadDir)
      image.gsub!('__LOCAL__', $imageUploadDir)
    end

    logging(image, "getWebIfImageName result")

    image
  end


  def change_character_for_webif
    logging("sendWebIfChangeCharacter begin")

    result = {}
    result['result'] = 'OK'

    begin
      change_character_chatched_for_webif
    rescue => e
      logging_exception(e)
      result['result'] = e.to_s
    end

    result
  end

  def change_character_chatched_for_webif
    logging("sendWebIfChangeCharacterChatched begin")

    target_name = request_text_for_webif('targetName')
    logging(target_name, "targetName")

    if target_name.empty?
      raise '変更するキャラクターの名前(\'target\'パラメータ）が正しく指定されていません'
    end


    change_save_data(@savefiles['characters']) do |saveData|

      character_data = character_by_name(saveData, target_name)
      logging(character_data, "characterData")

      if character_data.nil?
        raise "「#{target_name}」という名前のキャラクターは存在しません"
      end

      name = request_any_for_webif(:request_text_for_webif, 'name', character_data)
      logging(name, "name")

      if character_data['name'] != name
        failed_name = isAlreadyExistCharacterInRoom?(saveData, {'name' => name})
        if failed_name
          raise "「#{name}」という名前のキャラクターはすでに存在しています"
        end
      end

      character_data['name'] = name
      character_data['size'] = request_any_for_webif(:request_int_for_webif, 'size', character_data)
      character_data['x'] = request_any_for_webif(:request_number_for_webif, 'x', character_data)
      character_data['y'] = request_any_for_webif(:request_number_for_webif, 'y', character_data)
      character_data['initiative'] = request_any_for_webif(:request_number_for_webif, 'initiative', character_data)
      character_data['counters'] = request_any_for_webif(:request_hash_for_webif, 'counters', character_data)
      character_data['info'] = request_any_for_webif(:request_text_for_webif, 'info', character_data)
      character_data['imageName'] = request_any_for_webif(:image_name_for_webif, 'image', character_data, 'imageName')
      character_data['rotation'] = request_any_for_webif(:request_int_for_webif, 'rotation', character_data)
      character_data['statusAlias'] = request_any_for_webif(:request_hash_for_webif, 'statusAlias', character_data)
      character_data['dogTag'] = request_any_for_webif(:request_text_for_webif, 'dogTag', character_data)
      character_data['draggable'] = request_any_for_webif(:request_boolean_for_webif, 'draggable', character_data)
      character_data['isHide'] = request_any_for_webif(:request_boolean_for_webif, 'isHide', character_data)
      # 'type' => 'characterData',
      # 'imgId' =>  createCharacterImgId(),

    end

  end

  def character_by_name(save_data, target_name)
    characters = getCharactersFromSaveData(save_data)

    character_data = characters.find do |i|
      (i['name'] == target_name)
    end
  end


  def room_info_for_webif
    logging("getWebIfRoomInfo begin")

    result = {}
    result['result'] = 'OK'

    save_data(@savefiles['time']) do |saveData|
      logging(saveData, "saveData")
      round_time_data = hash_value(saveData, 'roundTimeData', {})
      result['counter'] = hash_value(round_time_data, "counterNames", [])
    end

    room_info = _room_info_for_webif
    result.merge!(room_info)

    logging(result, "getWebIfRoomInfo result")

    result
  end

  def _room_info_for_webif
    result = {}

    real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

    save_data(real_savefile_name) do |saveData|
      result['roomName'] = hash_value(saveData, 'playRoomName', '')
      result['chatTab'] = hash_value(saveData, 'chatChannelNames', [])
      result['outerImage'] = hash_value(saveData, 'canUseExternalImage', false)
      result['visit'] = hash_value(saveData, 'canVisit', false)
      result['game'] = hash_value(saveData, 'gameType', '')
    end

    result
  end

  #TODO:FIXME 削除候補メソッド (デフォルト値の設定含め、現状ではメソッド抽出するほどの処理ではない)
  def hash_value(hash, key, default)
    value = hash[key]
    value ||= default
  end

  def set_room_info_for_webif
    logging("setWebIfRoomInfo begin")

    result = {}
    result['result'] = 'OK'

    set_counter_names_in_room_info_webif

    real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

    room_info = _room_info_for_webif
    change_save_data(real_savefile_name) do |saveData|
      saveData['playRoomName'] = request_any_for_webif(:request_text_for_webif, 'roomName', room_info)
      saveData['chatChannelNames'] = request_any_for_webif(:request_array_for_webif, 'chatTab', room_info)
      saveData['canUseExternalImage'] = request_any_for_webif(:request_boolean_for_webif, 'outerImage', room_info)
      saveData['canVisit'] = request_any_for_webif(:request_boolean_for_webif, 'visit', room_info)
      saveData['gameType'] = request_any_for_webif(:request_text_for_webif, 'game', room_info)
    end

    logging(result, "setWebIfRoomInfo result")

    result
  end

  def set_counter_names_in_room_info_webif
    counter_names = request_array_for_webif('counter', nil, ',')
    return if (counter_names.nil?)

    change_counter_names(counter_names)
  end

  def change_counter_names(counter_names)
    logging(counter_names, "changeCounterNames(counterNames)")
    change_save_data(@savefiles['time']) do |saveData|
      saveData['roundTimeData'] ||= {}
      round_time_data = saveData['roundTimeData']
      round_time_data['counterNames'] = counter_names
    end
  end

  def request_any_for_webif(function_name, key, default_infos, key2 = nil) #TODO:WHAT? key,key2の具体的な値が不明
    key2 ||= key

    logging("getWebIfRequestAny begin")
    logging(key, "key")
    logging(key2, "key2")
    logging(default_infos, "defaultInfos")

    default_value = default_infos[key2]
    logging(default_value, "defaultValue")

    command = "#{function_name}( key, defaultValue )"
    logging(command, "getWebIfRequestAny command")

    result = eval(command)
    logging(result, "getWebIfRequestAny result")

    result
  end


  def refresh_for_webif
    logging("getWebIfRefresh Begin")

    chat_time = request_number_for_webif('chat', -1)

    @last_update_times = {
        'chatMessageDataLog' => chat_time,
        'map' => request_number_for_webif('map', -1),
        'characters' => request_number_for_webif('characters', -1),
        'time' => request_number_for_webif('time', -1),
        'effects' => request_number_for_webif('effects', -1),
        $playRoomInfoTypeName => request_number_for_webif('roomInfo', -1),
    }

    @last_update_times.delete_if { |type, time| time == -1 }
    logging(@last_update_times, "getWebIfRefresh lastUpdateTimes")

    save_data = {}
    refresh_routine(save_data)
    exclude_old_chat_for_webif(chat_time, save_data)

    result = {}
    ["chatMessageDataLog", "mapData", "characters", "graveyard", "effects"].each do |key|
      value = save_data.delete(key)
      next if (value.nil?)

      result[key] = value
    end

    result['roomInfo'] = save_data
    result['lastUpdateTimes'] = @last_update_times
    result['result'] = 'OK'

    logging("getWebIfRefresh End result", result)

    result
  end


  def refresh
    logging("==>Begin refresh")

    save_data = {}

    if $isMentenanceNow
      save_data["warning"] = {"key" => "canNotRefreshBecauseMentenanceNow"}
      return save_data
    end

    params = extract_params_in_request()
    logging(params, "params")

    @last_update_times = params['times']
    logging(@last_update_times, "@lastUpdateTimes")

    is_first_chat_refresh = (@last_update_times['chatMessageDataLog'] == 0)
    logging(is_first_chat_refresh, "isFirstChatRefresh")

    refresh_index = params['rIndex']
    logging(refresh_index, "refreshIndex")

    @isGetOwnRecord = params['isGetOwnRecord']

    if $isCommet
      refresh_routine(save_data)
    else
      refresh_once(save_data)
    end

    unique_id = command_sender
    user_name = params['name']
    is_visitor = params['isVisiter']

    login_user_info = login_user_info(user_name, unique_id, is_visitor)

    unless save_data.empty?
      save_data['lastUpdateTimes'] = @last_update_times
      save_data['refreshIndex'] = refresh_index
      save_data['loginUserInfo'] = login_user_info
    end

    if is_first_chat_refresh
      save_data['isFirstChatRefresh'] = is_first_chat_refresh
    end

    logging(save_data, "refresh end saveData")
    logging("==>End refresh")

    save_data
  end

  def login_user_info(user_name, unique_id, is_visitor)
    current_login_user_info = @savedir_info.real_savefile_name($loginUserInfo)
    update_login_user_info(current_login_user_info, user_name, unique_id, is_visitor)
  end


  def extract_params_in_request()
    params = request_data('params')
    logging(params, "params")
    params
  end


  def refresh_routine(save_data)
    now = Time.now
    while_limit_time = now + $refreshTimeout

    logging(now, "now")
    logging(while_limit_time, "whileLimitTime")

    while Time.now < while_limit_time

      refresh_once(save_data)

      break unless (save_data.empty?)

      intalval = refresh_interval
      logging(intalval, "saveData is empty, sleep second")
      sleep(intalval)
      logging("awake.")
    end
  end

  def refresh_interval
    if $isCommet
      $refreshInterval
    else
      $refreshIntervalForNotCommet
    end
  end

  def refresh_once(save_data)
    current_save_data() do |targetSaveData, saveFileTypeName|
      save_data.merge!(targetSaveData)
    end
  end


  def update_login_user_info(real_savefile_name, user_name = '', unique_id = '', is_visitor = false)
    logging(unique_id, 'updateLoginUserInfo uniqueId')
    logging(user_name, 'updateLoginUserInfo userName')

    result = []

    return result if (unique_id == -1)

    now_seconds = Time.now.to_i
    logging(now_seconds, 'nowSeconds')


    is_get_only = (user_name.empty? and unique_id.empty?)
    target_function = nil
    if is_get_only
      target_function = method(:save_data)
    else
      target_function = method(:change_save_data)
    end

    target_function.call(real_savefile_name) do |saveData|

      unless is_get_only
        change_user_info(saveData, unique_id, now_seconds, user_name, is_visitor)
      end

      saveData.delete_if do |existUserId, userInfo|
        delete_user_info?(existUserId, userInfo, now_seconds)
      end

      saveData.keys.sort.each do |userId|
        user_info = saveData[userId]
        data = {
            "userName" => user_info['userName'],
            "userId" => userId,
        }

        data['isVisiter'] = true if (user_info['isVisiter'])

        result << data
      end
    end

    result
  end

  def delete_user_info?(exist_user_id, user_info, now_seconds)
    is_logout = user_info['isLogout']
    return true if (is_logout)

    time_seconds = user_info['timeSeconds']
    diff_seconds = now_seconds - time_seconds
    (diff_seconds > $loginTimeOut)
  end

  def change_user_info(save_data, unique_id, now_seconds, user_name, is_visitor)
    return if (unique_id.empty?)

    is_logout = false
    if save_data.include?(unique_id)
      is_logout = save_data[unique_id]['isLogout']
    end

    return if (is_logout)

    user_info = {
        'userName' => user_name,
        'timeSeconds' => now_seconds,
    }

    user_info['isVisiter'] = true if (is_visitor)

    save_data[unique_id] = user_info
  end


  def play_room_name(save_data, index)
    play_room_name = save_data['playRoomName']
    play_room_name ||= "プレイルームNo.#{index}"
  end

  def login_user_count_list(target_range)
    result_list = {}
    target_range.each { |i| result_list[i] = 0 }

    @savedir_info.each_with_index(target_range, $loginUserInfo) do |saveFiles, index|
      next unless (target_range.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        result_list[index] = 0
        next
      end

      real_savefile_name = saveFiles.first

      login_user_info = update_login_user_info(real_savefile_name)
      result_list[index] = login_user_info.size
    end

    result_list
  end

  def login_user_list(target_range)
    login_user_list = {}
    target_range.each { |i| login_user_list[i] = [] }

    @savedir_info.each_with_index(target_range, $loginUserInfo) do |saveFiles, index|
      next unless (target_range.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        #loginUserList[index] = []
        next
      end

      user_names = []
      real_savefile_name = saveFiles.first
      login_user_info = update_login_user_info(real_savefile_name)
      login_user_info.each do |data|
        user_names << data["userName"]
      end

      login_user_list[index] = user_names
    end

    login_user_list
  end


  def save_data_lastaccess_times(target_range)
    @savedir_info.getSaveDataLastAccessTimes($saveFiles.values, target_range)
  end

  def save_data_lastaccess_time(file_name, room_no)
    data = @savedir_info.getSaveDataLastAccessTime(file_name, room_no)
    time = data[room_no]
  end


  def remove_old_play_room()
    all_ange = (0 .. $saveDataMaxCount)
    access_times = save_data_lastaccess_times(all_ange)
    remove_old_room_for_access_times(access_times)
  end

  def remove_old_room_for_access_times(access_times)
    logging("removeOldRoom Begin")
    if $removeOldPlayRoomLimitDays <= 0
      return access_times
    end

    logging(access_times, "accessTimes")

    target_rooms = delete_room_numbers(access_times)

    ignore_login_user = true
    password = nil
    result = remove_play_room_by_params(target_rooms, ignore_login_user, password)
    logging(result, "removePlayRoomByParams result")

    result
  end

  def delete_room_numbers(access_times)
    logging(access_times, "getDeleteTargetRoomNumbers accessTimes")

    room_numbers = []

    access_times.each do |index, time|
      logging(index, "index")
      logging(time, "time")

      next if (time.nil?)

      time_diff_sec = (Time.now - time)
      logging(time_diff_sec, "timeDiffSeconds")

      limit_sec = $removeOldPlayRoomLimitDays * 24 * 60 * 60
      logging(limit_sec, "limitSeconds")

      if time_diff_sec > limit_sec
        logging(index, "roomNumbers added index")
        room_numbers << index
      end
    end

    logging(room_numbers, "roomNumbers")
    room_numbers
  end


  def find_empty_room_number()
    empty_room_number = -1

    room_number_range = (0..$saveDataMaxCount)

    room_number_range.each do |roomNumber|
      @savedir_info.setSaveDataDirIndex(roomNumber)
      real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

      next if (exist?(real_savefile_name))

      empty_room_number = roomNumber
      break
    end

    empty_room_number
  end

  def play_room_states()
    params = extract_params_in_request()
    logging(params, "params")

    min_room = min_room(params)
    max_room = max_room(params)
    play_room_states = play_room_states_local(min_room, max_room)

    result = {
        "min_room" => min_room,
        "max_room" => max_room,
        "playRoomStates" => play_room_states,
    }

    logging(result, "getPlayRoomStatesLocal result")

    result
  end

  def play_room_states_local(min_room, max_room)
    room_number_range = (min_room .. max_room)
    play_room_states = []

    room_number_range.each do |roomNo|

      @savedir_info.setSaveDataDirIndex(roomNo)

      play_room_state = play_room_state(roomNo)
      next if (play_room_state.nil?)

      play_room_states << play_room_state
    end

    play_room_states
  end

  def play_room_state(room_no)

    # playRoomState = nil
    play_room_state = {}
    play_room_state['passwordLockState'] = false
    play_room_state['index'] = sprintf("%3d", room_no)
    play_room_state['playRoomName'] = "（空き部屋）"
    play_room_state['lastUpdateTime'] = ""
    play_room_state['canVisit'] = false
    play_room_state['gameType'] = ''
    play_room_state['login_users'] = []

    begin
      play_room_state = play_room_state_local(room_no, play_room_state)
    rescue => e
      loggingForce("getPlayRoomStateLocal rescue")
      logging_exception(e)
    rescue Exception => e
      loggingForce("getPlayRoomStateLocal Exception rescue")
      logging_exception(e)
    end

    play_room_state
  end

  def play_room_state_local(room_no, play_room_state)
    play_room_info_file = @savedir_info.real_savefile_name($playRoomInfo)

    return play_room_state unless (exist?(play_room_info_file))

    play_room_data = nil
    save_data(play_room_info_file) do |playRoomDataTmp|
      play_room_data = playRoomDataTmp
    end
    logging(play_room_data, "playRoomData")

    return play_room_state if (play_room_data.empty?)

    play_room_name = play_room_name(play_room_data, room_no)
    password_lock_state = (not play_room_data['playRoomChangedPassword'].nil?)
    can_visit = play_room_data['canVisit']
    game_type = play_room_data['gameType']
    timestamp = save_data_lastaccess_time($saveFiles['chatMessageDataLog'], room_no)

    time_display = ""
    unless timestamp.nil?
      time_display = "#{timestamp.strftime('%Y/%m/%d %H:%M:%S')}"
    end

    login_users = login_user_names()

    play_room_state['passwordLockState'] = password_lock_state
    play_room_state['playRoomName'] = play_room_name
    play_room_state['lastUpdateTime'] = time_display
    play_room_state['canVisit'] = can_visit
    play_room_state['gameType'] = game_type
    play_room_state['loginUsers'] = login_users

    play_room_state
  end

  def login_user_names()
    user_names = []

    real_savefile_name = @savedir_info.real_savefile_name($loginUserInfo)
    logging(real_savefile_name, "getLoginUserNames real_savefile_name")

    unless exist?(real_savefile_name)
      return user_names
    end

    @now_login_user_names ||= Time.now.to_i

    save_data(real_savefile_name) do |userInfos|
      userInfos.each do |uniqueId, userInfo|
        next if (delete_user_info?(uniqueId, userInfo, @now_login_user_names))
        user_names << userInfo['userName']
      end
    end

    logging(user_names, "getLoginUserNames user_names")
    user_names
  end

  def game_title(game_type)
    require 'diceBotInfos'
    dicebot_infos = DiceBotInfos.new.getInfos
    game_info = dicebot_infos.find { |i| i["gameType"] == game_type }

    return '--' if (game_info.nil?)

    game_info["name"]
  end


  def play_room_states_by_count()
    params = extract_params_in_request()
    logging(params, "params")

    min_room = min_room(params)
    count = params["count"]
    play_room_states = play_room_states_by_count_local(min_room, count)

    result = {
        "playRoomStates" => play_room_states,
    }

    logging(result, "getPlayRoomStatesByCount result")

    result
  end

  def play_room_states_by_count_local(start_room_no, count)
    play_room_states = []

    (start_room_no .. ($saveDataMaxCount - 1)).each do |roomNo|

      break if (play_room_states.length > count)

      @savedir_info.setSaveDataDirIndex(roomNo)

      play_room_state = play_room_state(roomNo)
      next if (play_room_state.nil?)

      play_room_states << play_room_state
    end

    play_room_states
  end


  def all_login_count()
    room_number_range = (0 .. $saveDataMaxCount)
    login_user_count_list = login_user_count_list(room_number_range)

    total = 0
    user_list = []

    login_user_count_list.each do |key, value|
      next if (value == 0)

      total += value
      user_list << [key, value]
    end

    user_list.sort!

    logging(total, "getAllLoginCount total")
    logging(user_list, "getAllLoginCount userList")
    return total, user_list
  end

  def famous_games
    room_number_range = (0 .. $saveDataMaxCount)
    game_type_list = getGameTypeList(room_number_range)

    counts = {}
    game_type_list.each do |roomNo, gameType|
      next if (gameType.empty?)

      counts[gameType] ||= 0
      counts[gameType] += 1
    end

    logging(counts, 'counts')

    count_list = counts.collect { |gameType, count| [count, gameType] }
    count_list.sort!
    count_list.reverse!

    logging('countList', count_list)

    famous_games = []

    count_list.each_with_index do |info, index|
      # next if( index >= 3 )

      count, game_type = info
      famous_games << {"gameType" => game_type, "count" => count}
    end

    logging('famousGames', famous_games)

    famous_games
  end


  def min_room(params)
    [[params['min_room'], 0].max, ($saveDataMaxCount - 1)].min
  end

  def max_room(params)
    [[params['max_room'], ($saveDataMaxCount - 1)].min, 0].max
  end

  def login_info()
    logging("getLoginInfo begin")

    params = extract_params_in_request()

    unique_id = params['uniqueId']
    unique_id ||= create_unique_id()

    all_login_count, login_user_count_list = all_login_count()
    write_all_login_info(all_login_count)

    login_message = login_message()
    card_infos = cards_info.collectCardTypeAndTypeName()
    dicebot_infos = dicebot_infos()

    result = {
        "loginMessage" => login_message,
        "cardInfos" => card_infos,
        "isDiceBotOn" => $isDiceBotOn,
        "uniqueId" => unique_id,
        "refreshTimeout" => $refreshTimeout,
        "refreshInterval" => refresh_interval(),
        "isCommet" => $isCommet,
        "version" => $version,
        "playRoomMaxNumber" => ($saveDataMaxCount - 1),
        "warning" => login_warning(),
        "playRoomGetRangeMax" => $playRoomGetRangeMax,
        "allLoginCount" => all_login_count.to_i,
        "limitLoginCount" => $limitLoginCount,
        "loginUserCountList" => login_user_count_list,
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
        'diceBotInfos' => dicebot_infos,
        'isNeedCreatePassword' => (not $createPlayRoomPassword.empty?),
        'defaultUserNames' => $defaultUserNames,
    }

    logging(result, "result")
    logging("getLoginInfo end")
    result
  end


  def create_unique_id
    # 識別子用の文字列生成。
    (Time.now.to_f * 1000).to_i.to_s(36)
  end

  def write_all_login_info(all_login_count)
    text = "#{all_login_count}"

    savefile_name = $loginCountFile
    lockfile = real_savefile_lock_readonly(savefile_name)

    lockfile.lock do
      File.open(savefile_name, "w+") do |file|
        file.write(text.toutf8)
      end
    end
  end


  def login_warning
    unless exist_dir?(getSmallImageDir)
      return {
          "key" => "noSmallImageDir",
          "params" => [getSmallImageDir],
      }
    end

    if $isMentenanceNow
      return {
          "key" => "canNotLoginBecauseMentenanceNow",
      }
    end

    nil
  end

  def login_message
    mesasge = ""
    mesasge << login_message_header
    mesasge << login_message_history_part
    mesasge
  end

  def login_message_header
    login_message = ""

    if File.exist?($loginMessageFile)
      File.readlines($loginMessageFile).each do |line|
        login_message << line.chomp << "\n"
      end
      logging(login_message, "loginMessage")
    else
      logging("#{$loginMessageFile} is NOT found.")
    end

    login_message
  end

  def login_message_history_part
    login_message = ""
    if File.exist?($loginMessageBaseFile)
      File.readlines($loginMessageBaseFile).each do |line|
        login_message << line.chomp << "\n"
      end
    else
      logging("#{$loginMessageFile} is NOT found.")
    end

    login_message
  end

  def dicebot_infos()
    logging("getDiceBotInfos() Begin")

    require 'diceBotInfos'
    dicebot_infos = DiceBotInfos.new.getInfos

    command_infos = game_command_infos

    command_infos.each do |commandInfo|
      logging(commandInfo, "commandInfos.each commandInfos")
      dicebot_prefix(dicebot_infos, commandInfo)
    end

    logging(dicebot_infos, "getDiceBotInfos diceBotInfos")

    dicebot_infos
  end

  def dicebot_prefix(dicebot_infos, command_info)
    game_type = command_info["gameType"]

    if game_type.empty?
      dicebot_prefix_all(dicebot_infos, command_info)
      return
    end

    bot_info = dicebot_infos.find { |i| i["gameType"] == game_type }
    dicebot_prefix_one(bot_info, command_info)
  end

  def dicebot_prefix_all(dicebot_infos, command_info)
    dicebot_infos.each do |botInfo|
      dicebot_prefix_one(botInfo, command_info)
    end
  end

  def dicebot_prefix_one(botinfo, command_info)
    logging(botinfo, "botInfo")
    return if (botinfo.nil?) #TODO:FIXME この条件式の戻り値はnull.かつこの条件が真である場合も以下のif条件は正常に動作し、同様にnullを返すので不要とおもわれる.

    prefixs = botinfo["prefixs"]
    return if (prefixs.nil?)

    prefixs << command_info["command"]
  end

  def game_command_infos
    logging('getGameCommandInfos Begin')

    if @savedir_info.getSaveDataDirIndex == -1
      logging('getGameCommandInfos room is -1, so END')

      return []
    end

    require 'cgiDiceBot.rb'
    bot = CgiDiceBot.new
    dir = getDiceBotExtraTableDirName
    logging(dir, 'dir')

    command_infos = bot.getGameCommandInfos(dir, @dicebot_table_prefix)
    logging(command_infos, "getGameCommandInfos End commandInfos")

    command_infos
  end


  def create_dir(play_room_index)
    @savedir_info.setSaveDataDirIndex(play_room_index)
    @savedir_info.create_dir
  end

  def create_play_room
    logging('createPlayRoom begin')

    result_text = "OK"
    play_room_index = -1
    begin
      params = extract_params_in_request()
      logging(params, "params")

      check_create_play_room_password(params['createPassword'])

      play_room_name = params['playRoomName']
      play_room_password = params['playRoomPassword']
      chat_channel_names = params['chatChannelNames']
      can_use_external_image = params['canUseExternalImage']

      can_visit = params['canVisit']
      play_room_index = params['playRoomIndex']

      if play_room_index == -1
        play_room_index = find_empty_room_number()
        raise Exception.new("noEmptyPlayRoom") if (play_room_index == -1)

        logging(play_room_index, "findEmptyRoomNumber playRoomIndex")
      end

      logging(play_room_name, 'playRoomName')
      logging('playRoomPassword is get')
      logging(play_room_index, 'playRoomIndex')

      init_savefiles(play_room_index)
      check_set_password(play_room_password, play_room_index)

      logging("@saveDirInfo.removeSaveDir(playRoomIndex) Begin")
      @savedir_info.removeSaveDir(play_room_index)
      logging("@saveDirInfo.removeSaveDir(playRoomIndex) End")

      create_dir(play_room_index)

      play_room_changed_password = changed_password(play_room_password)
      logging(play_room_changed_password, 'playRoomChangedPassword')

      view_states = params['viewStates']
      logging("viewStates", view_states)

      real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

      change_save_data(real_savefile_name) do |saveData|
        saveData['playRoomName'] = play_room_name
        saveData['playRoomChangedPassword'] = play_room_changed_password
        saveData['chatChannelNames'] = chat_channel_names
        saveData['canUseExternalImage'] = can_use_external_image
        saveData['canVisit'] = can_visit
        saveData['gameType'] = params['gameType']

        add_view_states_to_savedata(saveData, view_states)
      end

      send_room_create_message(play_room_index)
    rescue => e
      logging_exception(e)
      result_text = e.inspect + "$@ : " + $@.join("\n")
    rescue Exception => errorMessage
      result_text = errorMessage.to_s
    end

    result = {
        "resultText" => result_text,
        "playRoomIndex" => play_room_index,
    }
    logging(result, 'result')
    logging('createDir finished')

    result
  end

  def check_create_play_room_password(password)
    logging('checkCreatePlayRoomPassword Begin')
    logging(password, 'password')

    return if ($createPlayRoomPassword.empty?)
    return if ($createPlayRoomPassword == password)

    raise Exception.new("errorPassword")
  end


  def send_room_create_message(room_no)
    chat_data = {
        "senderName" => "どどんとふ",
        "message" => "＝＝＝＝＝＝＝　プレイルーム　【　No.　#{room_no}　】　へようこそ！　＝＝＝＝＝＝＝",
        "color" => "cc0066",
        "uniqueId" => '0',
        "channel" => 0,
    }

    sendChatMessageByChatData(chat_data)
  end


  def add_view_states_to_savedata(save_data, view_states)
    view_states['key'] = Time.now.to_f.to_s
    save_data['viewStateInfo'] = view_states
  end

  def changed_password(pass)
    return nil if (pass.empty?)

    salt = [rand(64), rand(64)].pack("C*").tr("\x00-\x3f", "A-Za-z0-9./")
    pass.crypt(salt)
  end

  def change_play_room()
    logging("changePlayRoom begin")

    result_text = "OK"

    begin
      params = extract_params_in_request()
      logging(params, "params")

      play_room_password = params['playRoomPassword']
      check_set_password(play_room_password)

      play_room_changed_password = changed_password(play_room_password)
      logging('playRoomPassword is get')

      view_states = params['viewStates']
      logging("viewStates", view_states)

      real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

      change_save_data(real_savefile_name) do |saveData|
        saveData['playRoomName'] = params['playRoomName']
        saveData['playRoomChangedPassword'] = play_room_changed_password
        saveData['chatChannelNames'] = params['chatChannelNames']
        saveData['canUseExternalImage'] = params['canUseExternalImage']
        saveData['canVisit'] = params['canVisit']
        saveData['backgroundImage'] = params['backgroundImage']
        saveData['gameType'] = params['gameType']

        preview_state_info = saveData['viewStateInfo']
        unless same_view_state?(view_states, preview_state_info)
          add_view_states_to_savedata(saveData, view_states)
        end

      end
    rescue => e
      logging_exception(e)
      result_text = e.to_s
    rescue Exception => e
      logging_exception(e)
      result_text = e.to_s
    end

    result = {
        "resultText" => result_text,
    }
    logging(result, 'changePlayRoom result')

    result
  end


  def check_set_password(play_room_password, room_number = nil)
    return if (play_room_password.empty?)

    if room_number.nil?
      room_number = @savedir_info.getSaveDataDirIndex
    end

    if $noPasswordPlayRoomNumbers.include?(room_number)
      raise Exception.new("noPasswordPlayRoomNumber")
    end
  end


  def same_view_state?(view_states, preview_state_info)
    result = true

    preview_state_info ||= {}

    view_states.each do |key, value|
      unless value == preview_state_info[key]
        result = false
        break
      end
    end

    result
  end


  def check_remove_play_room(room_number, ignore_login_user, password)
    room_number_range = (room_number..room_number)
    logging(room_number_range, "checkRemovePlayRoom roomNumberRange")

    unless ignore_login_user
      user_names = login_user_names
      user_count = user_names.size
      logging(user_count, "checkRemovePlayRoom userCount")

      if user_count > 0
        return "userExist"
      end
    end

    unless password.nil?
      unless check_password(room_number, password)
        return "password"
      end
    end

    if $unremovablePlayRoomNumbers.include?(room_number)
      return "unremovablePlayRoomNumber"
    end

    last_access_times = save_data_lastaccess_times(room_number_range)
    last_access_time = last_access_times[room_number]
    logging(last_access_time, "lastAccessTime")

    unless last_access_time.nil?
      now = Time.now
      spend_times = now - last_access_time
      logging(spend_times, "spendTimes")
      logging(spend_times / 60 / 60, "spendTimes / 60 / 60")
      if spend_times < $deletablePassedSeconds
        return "プレイルームNo.#{room_number}の最終更新時刻から#{$deletablePassedSeconds}秒が経過していないため削除できません"
      end
    end

    "OK"
  end


  def check_password(room_number, password)

    return true unless ($isPasswordNeedFroDeletePlayRoom)

    @savedir_info.setSaveDataDirIndex(room_number)
    real_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)
    exist_play_room_info = (exist?(real_savefile_name))

    return true unless (exist_play_room_info)

    matched = false
    save_data(real_savefile_name) do |saveData|
      changed_password = saveData['playRoomChangedPassword']
      matched = password_match?(password, changed_password)
    end

    matched
  end


  def remove_play_room
    params = extract_params_in_request()

    room_numbers = params['roomNumbers']
    ignore_login_user = params['ignoreLoginUser']
    password = params['password']
    password ||= ""

    remove_play_room_by_params(room_numbers, ignore_login_user, password)
  end

  def remove_play_room_by_params(room_numbers, ignore_login_user, password)
    logging(ignore_login_user, 'removePlayRoomByParams Begin ignoreLoginUser')

    deleted_room_numbers = []
    error_messages = []
    password_room_numbers = []
    ask_delete_room_numbers = []

    room_numbers.each do |room_number|
      room_number = room_number.to_i
      logging(room_number, 'roomNumber')

      result_text = check_remove_play_room(room_number, ignore_login_user, password)
      logging(result_text, "checkRemovePlayRoom resultText")

      case result_text
        when "OK"
          @savedir_info.removeSaveDir(room_number)
          remove_local_space_dir(room_number)
          deleted_room_numbers << room_number
        when "password"
          password_room_numbers << room_number
        when "userExist"
          ask_delete_room_numbers << room_number
        else
          error_messages << result_text
      end
    end

    result = {
        "deletedRoomNumbers" => deleted_room_numbers,
        "askDeleteRoomNumbers" => ask_delete_room_numbers,
        "passwordRoomNumbers" => password_room_numbers,
        "errorMessages" => error_messages,
    }
    logging(result, 'result')

    result
  end

  def remove_local_space_dir(room_number)
    dir = getRoomLocalSpaceDirNameByRoomNo(room_number)
    rmdir(dir)
  end

  def real_savefile_name(file_name)
    @savedir_info.real_savefile_name($saveFileTempName)
  end

  def save_scenario
    logging("saveScenario begin")
    dir = getRoomLocalSpaceDirName
    makeDir(dir)

    params = extract_params_in_request()
    @save_scenario_base_url = params['baseUrl']
    chat_palette_savedata_string = params['chatPaletteSaveData']

    all_save_data = savedata_all_for_scenario
    all_save_data = move_all_images_to_dir(dir, all_save_data)
    make_chat_pallet_savefile(dir, chat_palette_savedata_string)
    make_scenari_default_savefile(dir, all_save_data)

    remove_old_scenario_file(dir)
    base_name = get_new_savefile_base_name(@full_backup_base_name)
    scenario_file = make_scenario_file(dir, base_name)

    result = {}
    result['result'] = "OK"
    result["saveFileName"] = scenario_file

    logging(result, "saveScenario result")
    result
  end

  def savedata_all_for_scenario
    select_types = $saveFiles.keys
    select_types.delete_if { |i| i == 'chatMessageDataLog' }

    is_add_play_room_info = true
    get_select_files_data(select_types, is_add_play_room_info)
  end

  def move_all_images_to_dir(dir, savedata_all)
    logging(savedata_all, 'moveAllImagesToDir saveDataAll')

    move_map_image(dir, savedata_all)
    move_effects_image(dir, savedata_all)
    move_character_images(dir, savedata_all)
    move_playroom_images(dir, savedata_all)

    logging(savedata_all, 'moveAllImagesToDir result saveDataAll')

    savedata_all
  end

  def move_map_image(dir, all_savedata)
    map_data = getLoadData(all_savedata, 'map', 'mapData', {})
    image = map_data['imageSource']

    change_file_place(image, dir)
  end

  def move_effects_image(dir, all_savedata)
    effects = getLoadData(all_savedata, 'effects', 'effects', [])

    effects.each do |effect|
      image = effect['source']
      change_file_place(image, dir)
    end
  end

  def move_character_images(dir, all_savedata)
    characters = getLoadData(all_savedata, 'characters', 'characters', [])
    move_character_images_from_characters(dir, characters)

    characters = getLoadData(all_savedata, 'characters', 'graveyard', [])
    move_character_images_from_characters(dir, characters)

    characters = getLoadData(all_savedata, 'characters', 'waitingRoom', [])
    move_character_images_from_characters(dir, characters)
  end

  def move_character_images_from_characters(dir, characters)

    characters.each do |character|

      image_names = []

      case character['type']
        when 'characterData'
          image_names << character['imageName']
        when 'Card', 'CardMount', 'CardTrushMount'
          image_names << character['imageName']
          image_names << character['imageNameBack']
        when 'floorTile', 'chit'
          image_names << character['imageUrl']
        else

      end

      next if (image_names.empty?)

      image_names.each do |imageName|
        change_file_place(imageName, dir)
      end
    end
  end

  def move_playroom_images(dir, all_savedata)
    logging(dir, "movePlayroomImagesToDir dir")
    playroom_info = all_savedata['playRoomInfo']
    return if (playroom_info.nil?)
    logging(playroom_info, "playRoomInfo")

    background_image = playroom_info['backgroundImage']
    logging(background_image, "backgroundImage")
    return if (background_image.nil?)
    return if (background_image.empty?)

    change_file_place(background_image, dir)
  end

  def change_file_place(from, to)
    logging(from, "changeFilePlace from")

    from_file_name, text = from.split(/\t/)
    from_file_name ||= from

    result = copy_file(from_file_name, to)
    logging(result, "copyFile result")

    return unless (result)

    from.gsub!(/.*\//, $imageUploadDirMarker + "/")
    logging(from, "changeFilePlace result")
  end

  def copy_file(from, to)
    logging("moveFile begin")
    logging(from, "from")
    logging(to, "to")

    logging(@save_scenario_base_url, "@saveScenarioBaseUrl")
    from.gsub!(@save_scenario_base_url, './')
    logging(from, "from2")

    return false if (from.nil?)
    return false unless (File.exist?(from))

    from_dir = File.dirname(from)
    logging(from_dir, "fromDir")
    if from_dir == to
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

  def make_chat_pallet_savefile(dir, chat_palette_savedata_string)
    logging("makeChatPalletSaveFile Begin")
    logging(dir, "makeChatPalletSaveFile dir")

    current_dir = FileUtils.pwd.untaint
    FileUtils.cd(dir)

    File.open($scenarioDefaultChatPallete, "a+") do |file|
      file.write(chat_palette_savedata_string)
    end

    FileUtils.cd(current_dir)
    logging("makeChatPalletSaveFile End")
  end

  def make_scenari_default_savefile(dir, all_savedata)
    logging("makeScenariDefaultSaveFile Begin")
    logging(dir, "makeScenariDefaultSaveFile dir")

    extension = "sav"
    result = save_select_files_from_all_savedata(all_savedata, extension)

    from = result["saveFileName"]
    to = File.join(dir, $scenarioDefaultSaveData)

    FileUtils.mv(from, to)

    logging("makeScenariDefaultSaveFile End")
  end


  def remove_old_scenario_file(dir)
    file_names = Dir.glob("#{dir}/#{@full_backup_base_name}*#{@scenario_file_ext}")
    file_names = file_names.collect { |i| i.untaint }
    logging(file_names, "removeOldScenarioFile fileNames")

    file_names.each do |fileName|
      File.delete(fileName)
    end
  end

  def make_scenario_file(dir, base_name = "scenario")
    logging("makeScenarioFile begin")

    require 'zlib'
    require 'archive/tar/minitar'

    current_dir = FileUtils.pwd.untaint
    FileUtils.cd(dir)

    scenario_file = base_name + @scenario_file_ext
    tgz = Zlib::GzipWriter.new(File.open(scenario_file, 'wb'))

    file_names = Dir.glob('*')
    file_names = file_names.collect { |i| i.untaint }

    file_names.delete_if { |i| i == scenario_file }

    Archive::Tar::Minitar.pack(file_names, tgz)

    FileUtils.cd(current_dir)

    File.join(dir, scenario_file)
  end


  def save()
    is_add_playroom_info = true
    extension = request_data('extension')
    save_select_files($saveFiles.keys, extension, is_add_playroom_info)
  end

  def save_map()
    extension = request_data('extension')
    select_types = ['map', 'characters']
    save_select_files(select_types, extension)
  end


  def save_select_files(select_types, extension, is_add_playroom_info = false)
    all_savedata = get_select_files_data(select_types, is_add_playroom_info)
    save_select_files_from_all_savedata(all_savedata, extension)
  end

  def save_select_files_from_all_savedata(all_savedata, extension)
    result = {}
    result["result"] = "unknown error"

    if all_savedata.empty?
      result["result"] = "no save data"
      return result
    end

    delete_old_savefile

    save_data = {}
    save_data['saveDataAll'] = all_savedata

    text = build_json(save_data)
    savefile_name = get_new_savefile_name(extension)
    create_savefile(savefile_name, text)

    result["result"] = "OK"
    result["saveFileName"] = savefile_name
    logging(result, "saveSelectFiles result")

    result
  end


  def get_select_files_data(select_types, is_add_playroom_info = false)
    logging("getSelectFilesData begin")

    @last_update_times = {}
    select_types.each do |type|
      @last_update_times[type] = 0
    end
    logging("dummy @lastUpdateTimes created")

    all_savedata = {}
    current_save_data() do |targetSaveData, saveFileTypeName|
      all_savedata[saveFileTypeName] = targetSaveData
      logging(saveFileTypeName, "saveFileTypeName in save")
    end

    if is_add_playroom_info
      true_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)
      @last_update_times[$playRoomInfoTypeName] = 0
      if savefile_changed?(0, true_savefile_name)
        all_savedata[$playRoomInfoTypeName] = load_savefile($playRoomInfoTypeName, true_savefile_name)
      end
    end

    logging(all_savedata, "saveDataAll tmp")

    all_savedata
  end

  #override
  def file_join(*parts)
    File.join(*parts)
  end

  def get_new_savefile_name(extension)
    base_name = get_new_savefile_base_name("DodontoF")
    savefile_name = base_name + ".#{extension}"
    file_join($saveDataTempDir, savefile_name).untaint
  end

  def get_new_savefile_base_name(prefix)
    now = Time.now
    base_name = now.strftime(prefix + "_%Y_%m%d_%H%M%S_#{now.usec}")
    base_name.untaint
  end


  def delete_old_savefile
    logging('deleteOldSaveFile begin')
    begin
      delete_old_savefile_catched
    rescue => e
      logging_exception(e)
    end
    logging('deleteOldSaveFile end')
  end

  def delete_old_savefile_catched

    change_save_data($saveFileNames) do |saveData|
      exist_file_names = saveData["fileNames"]
      exist_file_names ||= []
      logging(exist_file_names, 'existSaveFileNames')

      regexp = /DodontoF_[\d_]+.sav/

      delete_targets = []

      exist_file_names.each do |saveFileName|
        logging(saveFileName, 'saveFileName')
        next unless (regexp === saveFileName)

        created_time = savefile_timestamp(saveFileName)
        now = Time.now.to_i
        diff = (now - created_time)
        logging(diff, "createdTime diff")
        next if (diff < $oldSaveFileDelteSeconds)

        begin
          deleteFile(saveFileName)
        rescue => e
          logging_exception(e)
        end

        delete_targets << saveFileName
      end

      logging(delete_targets, "deleteTargets")

      delete_targets.each do |fileName|
        exist_file_names.delete_if { |i| i == fileName }
      end
      logging(exist_file_names, "existSaveFileNames")

      saveData["fileNames"] = exist_file_names
    end

  end


  def logging_exception(e)
    self.class.logging_exception(e)
  end

  def self.logging_exception(e)
    loggingForce(e.to_s, "exception mean")
    loggingForce($@.join("\n"), "exception from")
    loggingForce($!.inspect, "$!.inspect")
  end


  def check_room_status()
    deleteOldUploadFile()

    check_room_status_data = extract_params_in_request()
    logging(check_room_status_data, 'checkRoomStatusData')

    room_number = check_room_status_data['roomNumber']
    logging(room_number, 'roomNumber')

    @savedir_info.setSaveDataDirIndex(room_number)

    is_maintenance_on = false
    is_welcome_message_on = $isWelcomeMessageOn
    play_room_name = ''
    chat_channel_names = nil
    can_use_external_image = false
    can_visit = false
    is_password_locked = false
    true_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)
    is_exist_playroom_info = (exist?(true_savefile_name))

    if is_exist_playroom_info
      save_data(true_savefile_name) do |saveData|
        play_room_name = play_room_name(saveData, room_number)
        changedPassword = saveData['playRoomChangedPassword']
        chat_channel_names = saveData['chatChannelNames']
        can_use_external_image = saveData['canUseExternalImage']
        can_visit = saveData['canVisit']
        unless changedPassword.nil?
          is_password_locked = true
        end
      end
    end

    unless $mentenanceModePassword.nil?
      if check_room_status_data["adminPassword"] == $mentenanceModePassword
        is_password_locked = false
        is_welcome_message_on = false
        is_maintenance_on = true
      end
    end

    logging("isPasswordLocked", is_password_locked)

    result = {
        'isRoomExist' => is_exist_playroom_info,
        'roomName' => play_room_name,
        'roomNumber' => room_number,
        'chatChannelNames' => chat_channel_names,
        'canUseExternalImage' => can_use_external_image,
        'canVisit' => can_visit,
        'isPasswordLocked' => is_password_locked,
        'isMentenanceModeOn' => is_maintenance_on,
        'isWelcomeMessageOn' => is_welcome_message_on,
    }

    logging(result, "checkRoomStatus End result")

    result
  end

  def login_password()
    login_data = extract_params_in_request()
    logging(login_data, 'loginData')

    room_number = login_data['roomNumber']
    password = login_data['password']
    visiter_mode = login_data['visiterMode']

    check_login_password(room_number, password, visiter_mode)
  end

  def check_login_password(room_number, password, visitor_mode)
    logging("checkLoginPassword roomNumber", room_number)
    @savedir_info.setSaveDataDirIndex(room_number)
    dir_name = @savedir_info.getDirName()

    result = {
        'resultText' => '',
        'visiterMode' => false,
        'roomNumber' => room_number,
    }

    is_room_exist = (exist_dir?(dir_name))

    unless is_room_exist
      result['resultText'] = "プレイルームNo.#{room_number}は作成されていません"
      return result
    end


    true_savefile_name = @savedir_info.real_savefile_name($playRoomInfo)

    save_data(true_savefile_name) do |saveData|
      can_visit = saveData['canVisit']
      if can_visit and visitor_mode
        result['resultText'] = "OK"
        result['visiterMode'] = true
      else
        changed_password = saveData['playRoomChangedPassword']
        if password_match?(password, changed_password)
          result['resultText'] = "OK"
        else
          result['resultText'] = "パスワードが違います"
        end
      end
    end

    result
  end

  def password_match?(password, changed_password)
    return true if (changed_password.nil?)
    (password.crypt(changed_password) == changed_password)
  end


  def logout()
    logout_data = extract_params_in_request()
    logging(logout_data, 'logoutData')

    unique_id = logout_data['uniqueId']
    logging(unique_id, 'uniqueId')

    true_savefile_name = @savedir_info.real_savefile_name($loginUserInfo)
    change_save_data(true_savefile_name) do |saveData|
      saveData.each do |existUserId, userInfo|
        logging(existUserId, "existUserId in logout check")
        logging(unique_id, 'uniqueId in logout check')

        if existUserId == unique_id
          userInfo['isLogout'] = true
        end
      end

      logging(saveData, 'saveData in logout')
    end
  end


  def check_filesize_on_mb(data, max_file_size)
    error = false

    limit = (max_file_size * 1024 * 1024)

    if data.size > limit
      error = true
    end

    if error
      return "ファイルサイズが最大値(#{max_file_size}MB)以上のためアップロードに失敗しました。"
    end

    ""
  end


  def get_bot_table_infos()
    logging("getBotTableInfos Begin")
    result = {
        "resultText" => "OK",
    }

    dir = getDiceBotExtraTableDirName
    result["tableInfos"] = get_bot_table_infos_from_dir(dir)

    logging(result, "result")
    logging("getBotTableInfos End")
    result
  end

  def get_bot_table_infos_from_dir(dir)
    logging(dir, 'getBotTableInfosFromDir dir')

    require 'TableFileData'

    is_load_common_table = false
    table_file_data = TableFileData.new(is_load_common_table)
    table_file_data.setDir(dir, @dicebot_table_prefix)
    table_infos = table_file_data.getAllTableInfo

    logging(table_infos, "getBotTableInfosFromDir tableInfos")
    table_infos.sort! { |a, b| a["command"].to_i <=> b["command"].to_i }

    logging(table_infos, 'getBotTableInfosFromDir result tableInfos')

    table_infos
  end


  def add_bot_table()
    result = {}
    result['resultText'] = add_bot_table_main()

    if result['resultText'] != "OK"
      return result
    end

    logging("addBotTableMain called")

    result = get_bot_table_infos()
    logging(result, "addBotTable result")

    result
  end

  def add_bot_table_main()
    logging("addBotTableMain Begin")

    dir = getDiceBotExtraTableDirName
    makeDir(dir)
    params = extract_params_in_request()

    require 'TableFileData'

    result_text = 'OK'
    begin
      creator = TableFileCreator.new(dir, @dicebot_table_prefix, params)
      creator.execute
    rescue Exception => e
      logging_exception(e)
      result_text = e.to_s
    end

    logging(result_text, "addBotTableMain End resultText")

    result_text
  end


  def change_bot_table()
    result = {}
    result['resultText'] = change_bot_table_main()

    if result['resultText'] != "OK"
      return result
    end

    get_bot_table_infos()
  end

  def change_bot_table_main()
    logging("changeBotTableMain Begin")

    dir = getDiceBotExtraTableDirName
    params = extract_params_in_request()

    require 'TableFileData'

    result_text = 'OK'
    begin
      creator = TableFileEditer.new(dir, @dicebot_table_prefix, params)
      creator.execute
    rescue Exception => e
      logging_exception(e)
      result_text = e.to_s
    end

    logging(result_text, "changeBotTableMain End resultText")

    result_text
  end


  def remove_bot_table()
    remove_bot_table_main
    get_bot_table_infos
  end

  def remove_bot_table_main()
    logging("removeBotTableMain Begin")

    params = extract_params_in_request()
    command = params["command"]

    dir = getDiceBotExtraTableDirName

    require 'TableFileData'

    is_load_common_table = false
    table_file_Data = TableFileData.new(is_load_common_table)
    table_file_Data.setDir(dir, @dicebot_table_prefix)
    table_infos = table_file_Data.getAllTableInfo

    table_info = table_infos.find { |i| i["command"] == command }
    logging(table_info, "tableInfo")
    return if (table_info.nil?)

    file_name = table_info["fileName"]
    logging(file_name, "fileName")
    return if (file_name.nil?)

    logging("isFile exist?")
    return unless (File.exist?(file_name))

    begin
      File.delete(file_name)
    rescue Exception => e
      logging_exception(e)
    end

    logging("removeBotTableMain End")
  end


  def request_replay_data_list()
    logging("requestReplayDataList begin")
    result = {
        "resultText" => "OK",
    }

    result["replayDataList"] = get_replay_data_list() #[{"title"=>x, "url"=>y}]

    logging(result, "result")
    logging("requestReplayDataList end")
    result
  end

  def upload_replay_data()
    uploadFileBase($replayDataUploadDir, $UPLOAD_REPALY_DATA_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|
      logging("uploadReplayData yield Begin")

      params = extract_params_in_request()

      own_url = params['ownUrl']
      replay_url = own_url + "?replay=" + CGI.escape(fileNameFullPath)

      replay_data_name = params['replayDataName']
      replay_data_info = set_replay_data_info(fileNameFullPath, replay_data_name, replay_url)

      result["replayDataInfo"] = replay_data_info
      result["replayDataList"] = get_replay_data_list() #[{"title"=>x, "url"=>y}]

      logging("uploadReplayData yield End")
    end

  end

  def get_replay_data_list
    replay_data_list = nil

    save_data(get_replay_data_info_file_name()) do |saveData|
      replay_data_list = saveData['replayDataList']
    end

    replay_data_list ||= []

    replay_data_list
  end

  def get_replay_data_info_file_name
    info_file_name = file_join($replayDataUploadDir, 'replayDataInfo.json')
    info_file_name
  end


  #getImageInfoFileName() ) do |saveData|
  def set_replay_data_info(file_name, title, url)

    replay_data_info = {
        "fileName" => file_name,
        "title" => title,
        "url" => url,
    }

    change_save_data(get_replay_data_info_file_name()) do |saveData|
      saveData['replayDataList'] ||= []
      replay_data_list = saveData['replayDataList']
      replay_data_list << replay_data_info
    end

    replay_data_info
  end


  def removeReplayData()
    logging("removeReplayData begin")

    result = {
        "resultText" => "NG",
    }

    begin
      replayData = extract_params_in_request()

      logging(replayData, "replayData")

      replayDataList = []
      change_save_data(get_replay_data_info_file_name()) do |saveData|
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

      result = request_replay_data_list()
    rescue => e
      result["resultText"] = e.to_s
      logging_exception(e)
    end

    result
  end


  def uploadFile()
    uploadFileBase($fileUploadDir, $UPLOAD_FILE_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|

      deleteOldUploadFile()

      params = extract_params_in_request()
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
      logging_exception(e)
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

      params = extract_params_in_request()

      fileData = params['fileData']

      sizeCheckResult = check_filesize_on_mb(fileData, fileMaxSize)
      if sizeCheckResult != ""
        result["resultText"] = sizeCheckResult
        return result
      end

      fileNameOriginal = params['fileName'].toutf8

      fileName = fileNameOriginal
      if isChangeFileName
        fileName = getNewFileName(fileNameOriginal)
      end

      fileNameFullPath = file_join(fileUploadDir, fileName).untaint
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

      params = extract_params_in_request()
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
    params = extract_params_in_request()

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
          change_initiative_data(roundTimeData)
        else
          loggingForce(target, "invalid load target type")
      end
    end
  end

  def loadSaveFileDataAll(saveDataAll)
    logging("loadSaveFileDataAll(saveDataAll) begin")

    @savefiles.each do |fileTypeName, trueSaveFileName|
      logging(fileTypeName, "fileTypeName")
      logging(trueSaveFileName, "real_savefile_name")

      saveDataForType = saveDataAll[fileTypeName]
      saveDataForType ||= {}
      logging(saveDataForType, "saveDataForType")

      loadSaveFileDataForEachType(fileTypeName, trueSaveFileName, saveDataForType)
    end

    if saveDataAll.include?($playRoomInfoTypeName)
      trueSaveFileName = @savedir_info.real_savefile_name($playRoomInfo)
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
    smallImageDir = file_join(saveDir, smallImageDirName)

    smallImageDir
  end

  def saveSmallImage(smallImageData, imageFileNameBase, uploadImageFileName)
    logging("saveSmallImage begin")
    logging(imageFileNameBase, "imageFileNameBase")
    logging(uploadImageFileName, "uploadImageFileName")

    smallImageDir = getSmallImageDir
    uploadSmallImageFileName = file_join(smallImageDir, imageFileNameBase)
    uploadSmallImageFileName += ".png"
    uploadSmallImageFileName.untaint
    logging(uploadSmallImageFileName, "uploadSmallImageFileName")

    open(uploadSmallImageFileName, "wb+") do |file|
      file.write(smallImageData)
    end
    logging("small image create successed.")

    params = extract_params_in_request()
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
      params = extract_params_in_request()

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

      uploadImageFileName = file_join(saveDir, imageFileNameBase)
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

    sizeCheckResult = check_filesize_on_mb(value, $UPLOAD_IMAGE_MAX_SIZE)
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

    imageData = extract_params_in_request()
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

    imageData = extract_params_in_request()
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

    params = extract_params_in_request()

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
    chatData = extract_params_in_request()

    password = chatData["password"]
    logging(password, "password check...")
    return result unless (password == $mentenanceModePassword)

    logging("adminPoassword check OK.")

    rooms = []

    $saveDataMaxCount.times do |roomNumber|
      logging(roomNumber, "loop roomNumber")

      init_savefiles(roomNumber)

      trueSaveFileName = @savedir_info.real_savefile_name($playRoomInfo)
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
    chatData = extract_params_in_request()
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

    file = @savedir_info.real_savefile_name($chatMessageDataLogAll)
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

    saveFileName = @savedir_info.real_savefile_name($chatMessageDataLogAll)

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
    mapData = extract_params_in_request()
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

    params = extract_params_in_request()
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
    effectData = extract_params_in_request()
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
      effectData = extract_params_in_request()
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
      params = extract_params_in_request()
      effectId = params['effectId']
      logging(effectId, 'effectId')

      saveData['effects'] ||= []
      effects = saveData['effects']
      effects.delete_if { |i| (effectId == i['effectId']) }
    end

    logging('removeEffect End')
  end


  def getImageInfoFileName
    imageInfoFileName = file_join($imageUploadDir, 'imageInfo.json')

    logging(imageInfoFileName, 'imageInfoFileName')

    imageInfoFileName
  end

  def changeImageTags()
    effectData = extract_params_in_request()
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
        errorMessage = error_response_body(e)
        logging_exception(e)
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
    characterData = extract_params_in_request()
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
    characterData = extract_params_in_request()
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

    data = extract_params_in_request()

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


    params = extract_params_in_request()
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

    addCardData = extract_params_in_request()

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

    params = extract_params_in_request()

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

    params = extract_params_in_request()
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

    params = extract_params_in_request()

    mount_name = params['mountName']
    logging(mount_name, "mountName")

    change_save_data(@savefiles['characters']) do |saveData|

      trush_mount, trush_cards = findTrushMountAndTrushCards(saveData, mount_name)

      card_data = remove_from_array(trush_cards) { |i| i['imgId'] === params['targetCardId'] }
      logging(card_data, "cardData")
      return if (card_data.nil?)

      card_data['x'] = params['x']
      card_data['y'] = params['y']

      characters = getCharactersFromSaveData(saveData)
      characters.push(card_data)

      trushMountData = findCardData(characters, params['mountId'])
      logging(trushMountData, "returnCard trushMountData")

      return if (trushMountData.nil?)

      setTrushMountDataCardsInfo(saveData, trushMountData, trush_cards)
    end

    logging("drawTargetTrushCard End")

    return {"result" => "OK"}
  end

  def drawTargetCard
    logging("drawTargetCard Begin")

    set_no_body_sender

    params = extract_params_in_request()
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

    dumpTrushCardsData = extract_params_in_request()
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

    params = extract_params_in_request()
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

    params = extract_params_in_request()
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
    params = extract_params_in_request()
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
    params = extract_params_in_request()
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

    clearData = extract_params_in_request()
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
    removeCharacterDataList = extract_params_in_request()
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

    params = extract_params_in_request()
    characterId = params['characterId']

    logging(characterId, "enterWaitingRoomCharacter characterId")

    result = {"result" => "NG"}
    change_save_data(@savefiles['characters']) do |saveData|
      characters = getCharactersFromSaveData(saveData)

      enterCharacterData = remove_from_array(characters) { |i| (i['imgId'] == characterId) }
      return result if (enterCharacterData.nil?)

      waitingRoom = getWaitinigRoomFromSaveData(saveData)
      waitingRoom << enterCharacterData
    end

    result["result"] = "OK"
    result
  end


  def resurrectCharacter
    params = extract_params_in_request()
    resurrectCharacterId = params['imgId']
    logging(resurrectCharacterId, "resurrectCharacterId")

    change_save_data(@savefiles['characters']) do |saveData|
      graveyard = getGraveyardFromSaveData(saveData)

      characterData = remove_from_array(graveyard) do |character|
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


  def getGraveyardFromSaveData(save_data)
    getArrayInfoFromHash(save_data, 'graveyard')
  end

  def getWaitinigRoomFromSaveData(save_data)
    getArrayInfoFromHash(save_data, 'waitingRoom')
  end

  def getCharactersFromSaveData(save_data)
    getArrayInfoFromHash(save_data, 'characters')
  end

  def getCardsFromCardMount(card_mount, mount_name)
    getArrayInfoFromHash(card_mount, mount_name)
  end

  def getArrayInfoFromHash(hash, key)
    hash[key] ||= []
    hash[key]
  end

  def getCardMountFromSaveData(save_data)
    getHashInfoFromHash(save_data, 'cardMount')
  end

  def getHashInfoFromHash(hash, key)
    hash[key] ||= {}
    hash[key]
  end


  def exitWaitingRoomCharacter

    set_record_empty

    params = extract_params_in_request()
    targetCharacterId = params['characterId']
    x = params['x']
    y = params['y']
    logging(targetCharacterId, 'exitWaitingRoomCharacter targetCharacterId')

    result = {"result" => "NG"}
    change_save_data(@savefiles['characters']) do |saveData|
      waitingRoom = getWaitinigRoomFromSaveData(saveData)

      characterData = remove_from_array(waitingRoom) do |character|
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


  def remove_from_array(array)
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


  def change_round_time
    round_time_data = extract_params_in_request()
    change_initiative_data(round_time_data)
  end

  def change_initiative_data(round_time_data)
    change_save_data(@savefiles['time']) do |saveData|
      saveData['roundTimeData'] = round_time_data
    end
  end


  def move_character()
    change_save_data(@savefiles['characters']) do |saveData|

      character_move_data = extract_params_in_request()
      logging(character_move_data, "moveCharacter() characterMoveData")

      logging(character_move_data['imgId'], "character.imgId")

      characters = getCharactersFromSaveData(saveData)

      characters.each do |characterData|
        next unless (characterData['imgId'] == character_move_data['imgId'])

        characterData['x'] = character_move_data['x']
        characterData['y'] = character_move_data['y']

        break
      end

      logging(characters, "after moved characters")

    end
  end

  #override
  def savefile_timestamp(savefile_name)
    unless exist?(savefile_name)
      return 0
    end

    timestamp = File.mtime(savefile_name).to_f
  end

  def savefile_timestamp_millisec(savefile_name)
    (savefile_timestamp(savefile_name) * 1000).to_i
  end

  def savefile_changed?(last_update_time, savefile_name)
    last_update_time = last_update_time.to_i
    savefile_timestamp = savefile_timestamp_millisec(savefile_name)
    changed = (savefile_timestamp != last_update_time)

    logging(savefile_name, "saveFileName")
    logging(savefile_timestamp.inspect, "saveFileTimeStamp")
    logging(last_update_time.inspect, "lastUpdateTime   ")
    logging(changed, "changed")

    changed
  end

  def response_body
    response = analyze_command

    if isJsonResult
      build_json(response)
    else
      build_msgpack(response)
    end
  end
end


def error_response_body(e)
  error_message <<-ERR
  e.to_s : #{e.to_s}
  e.inspect : #{e.inspect}
  $@ : #{$@.join("\n")}
  $! : #{$!.to_s("\n")}
  ERR

  error_message
end


def compress?(result, server)
  return false if ($gzipTargetSize <= 0)
  return false if (server.jsonp_callback)

  ((/gzip/ =~ ENV["HTTP_ACCEPT_ENCODING"]) and (result.length > $gzipTargetSize))
end

def compress_response(result)
  require 'zlib'
  require 'stringio'

  io = StringIO.new
  Zlib::GzipWriter.wrap(io) do |gz|
    gz.write(result)
    gz.flush
    gz.finish
  end

  compressed = io.string
  logging(compressed.length.to_s, "CGI response zipped length  ")

  compressed
end


def main(params)
  logging("main called")
  server = DodontoFServer.new(SaveDirInfo.new(), params)
  logging("server created")
  print_response(server)
  logging("printResult called")
end

def response_header(server)
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

def print_response(server)
  logging("========================================>CGI begin.")

  text = "empty"

  header = response_header(server)

  begin
    result = server.response_body

    if server.is_add_marker
      result = "#D@EM>#" + result + "#<D@EM#"
    end

    if server.jsonp_callback
      result = "#{server.jsonpCallBack}(" + result + ");"
    end

    logging(result.length.to_s, "CGI response original length")

    if compress?(result, server)
      if $isModRuby
        Apache.request.content_encoding = 'gzip'
      else
        header << "Content-Encoding: gzip\n"

        if server.jsonpCallBack
          header << "Access-Control-Allow-Origin: *\n"
        end
      end

      text = compress_response(result)
    else
      text = result
    end
  rescue Exception => e
    error_message = error_response_body(e)
    loggingForce(error_message, "errorMessage")

    text = "\n= ERROR ====================\n"
    text << error_message
    text << "============================\n"
  end

  logging(header, "RESPONSE header")

  output = $stdout
  output.binmode if (defined?(output.binmode))

  output.print(header + "\n")

  output.print(text)

  logging("========================================>CGI end.")
end


def extract_params_in_cgi()
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
  params = DodontoFServer.parse_msgpack(input)

  logging(params, "messagePackedData")
  logging("getCgiParams End")

  params
end


def execute_server()
  initLog()

  params = extract_params_in_cgi()

  case $dbType
    when "mysql"
      #mod_ruby でも再読み込みするようにloadに
      require 'DodontoFServerMySql.rb'
      mainMySql(params)
    else
      #通常のテキストファイル形式
      main(params)
  end

end

if $0 === __FILE__
  execute_server()
end
