#!/usr/local/bin/ruby -Ku
# encoding: utf-8
$LOAD_PATH << File.dirname(__FILE__) + '/src_ruby'
$LOAD_PATH << File.dirname(__FILE__) + '/src_bcdice'

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

$save_file_names = File.join($saveDataTempDir, 'saveFileNames.json')
$image_url_text  = File.join($imageUploadDir, 'imageUrl.txt')

$chat_long_line_file_name = 'chatLongLines.txt'

$login_user_info_file_name = 'login.json'
$play_room_info_file_name  = 'playRoomInfo.json'
$play_room_info_type_name  = 'playRoomInfo'

$save_files_name_set = {
    'chatMessageDataLog'      => 'chat.json',
    'map'                     => 'map.json',
    'characters'              => 'characters.json',
    'time'                    => 'time.json',
    'effects'                 => 'effects.json',
    $play_room_info_type_name => $play_room_info_file_name,
}

$record_key = 'record'
$record     = 'record.json'


class DodontoFServer

  attr :is_add_marker
  attr :jsonp_callback
  attr :is_json_result

  def initialize(savedir_info, request_params)
    @request_params = request_params
    @savedir_info   = savedir_info

    room_index_key = "room"
    init_savefiles(request_data(room_index_key))

    @is_add_marker    = false
    @jsonp_callback   = nil
    @is_web_interface = false
    @is_json_result   = true
    @is_record_empty  = false

    @dicebot_table_prefix  = 'diceBotTable_'
    @full_backup_base_name = "DodontoFFullBackup"
    @scenario_file_ext     = '.tar.gz'
    @card                  = nil
  end

  def init_savefiles(room_index)
    @savedir_info.init(room_index, $saveDataMaxCount, $SAVE_DATA_DIR)

    @savefiles = {}
    $save_files_name_set.each do |key_name, file_name|
      logging(key_name, 'saveDataKeyName')
      logging(file_name, 'saveFileName')
      @savefiles[key_name] = @savedir_info.real_savefile_name(file_name)
    end

  end


  #TODO:FIXME 1requestにつき1インスタンスでなければこの処理は成立しないので後々改修の余地があり.
  def request_data(key)
    logging(key, "getRequestData key")

    value = @request_params[key]
    logging(@request_params, "@cgiParams")
    # logging(value, "getRequestData value")

    #TODO:WAHT? このCGIインスタンスを生成する処理の理由がわからない
    if value.nil? and @is_web_interface
      @cgi  ||= CGI.new
      value = @cgi.request_params[key].first
    end

    logging(value, "getRequestData result")
    value
  end

  def cards_info
    require "card.rb"

    @card ||= Card.new
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
      lockfile_name = DodontoFServer::lockfile_name(file_name)
      return FileLock.new(lockfile_name)
        #return FileLock2.new(saveFileName + ".lock", isReadOnly)
    rescue => e
      loggingForce(@savedir_info.inspect, "when getSaveFileLock error : @saveDirInfo.inspect")
      raise
    end
  end

  def load_long_chatlog(type_name, savefile_name)
    savefile_name = @savedir_info.real_savefile_name($chat_long_line_file_name)
    lockfile      = savefile_lock_readonly(savefile_name)

    lines = []
    lockfile.lock do
      if File.exist?(savefile_name)
        lines = File.readlines(savefile_name)
      end

      @last_update_times[type_name] = savefile_timestamp_millisec(savefile_name)
    end

    if lines.empty?
      return {}
    end

    log_data = lines.collect { |line| DodontoFServer::parse_json(line.chomp) }

    { "chatMessageDataLog" => log_data }
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
    type_name == 'chatMessageDataLog'
  end


  def character_file?(type_name)
    type_name == "characters"
  end

  def load_character(type_name, file_name)
    logging(@last_update_times, "loadSaveFileForCharacter begin @lastUpdateTimes")

    character_update_time = savefile_timestamp_millisec(file_name)

    #後の操作順序に依存せずRecord情報が取得できるよう、ここでRecordをキャッシュしておく。
    #こうしないとRecordを取得する順序でセーブデータと整合性が崩れる場合があるため
    record_caching

    save_data = record_by_cache
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

  def record_by_cache
    record_index = @last_update_times['recordIndex']

    logging("getRecordSaveDataFromCash begin")
    logging(record_index, "recordIndex")
    logging(@record, "@record")

    return nil if (record_index.nil?)
    return nil if (record_index == 0)
    return nil if (@record.nil?)
    return nil if (@record.empty?)

    current_sender = command_sender
    found          = false

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
      save_data = { 'record' => record_data }
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
    save_data          = load_default_savefile($record_key, real_savefile_name)
    @record            = record_by_save_data(save_data)
  end

  def load_default_savefile(type_name, file_name)
    lockfile = savefile_lock_readonly(file_name)

    text_data = ""
    lockfile.lock do
      @last_update_times[type_name] = savefile_timestamp_millisec(file_name)
      text_data                     = extract_safed_file_text(file_name)
    end

    DodontoFServer::parse_json(text_data)
  end

  def save_data(savefile_name)
    lockfile = savefile_lock(savefile_name, true)

    text_data = nil
    lockfile.lock do
      text_data = extract_safed_file_text(savefile_name)
    end

    save_data = DodontoFServer::parse_json(text_data)
    yield(save_data)
  end

  def change_save_data(savefile_name)

    character_data = (@savefiles['characters'] == savefile_name)

    lockfile = savefile_lock(savefile_name)

    lockfile.lock do
      text_data = extract_safed_file_text(savefile_name)
      save_data = DodontoFServer::parse_json(text_data)

      if character_data
        save_character_history(save_data) do
          yield(save_data)
        end
      else
        yield(save_data)
      end

      text_data = DodontoFServer::build_json(save_data)
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

    added   = not_exist_characters(after, before)
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
    save_data           ||= {}
    save_data['record'] ||= []

    save_data['record']
  end

  def create_savefile(file_name, text)
    logging(file_name, 'createSaveFile saveFileName')
    exist_files = nil

    logging($save_file_names, "$saveFileNames")
    change_save_data($save_file_names) do |save_data|
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

  def self.build_json(source_data)
    return JsonBuilder.new.build(source_data)
  end

  def self.build_msgpack(data)
    if $isMessagePackInstalled
      MessagePack.pack(data)
    else
      MessagePackPure::Packer.new(StringIO.new).write(data).string
    end
  end

  def self.parse_json(text)
    parsed_data = nil
    begin
      logging(text, "getJsonDataFromText start")
      begin
        parsed_data = JsonParser.new.parse(text)
        logging("getJsonDataFromText 1 end")
      rescue => e
        text        = CGI.unescape(text)
        parsed_data = JsonParser.new.parse(text)
        logging("getJsonDataFromText 2 end")
      end
    rescue => e
      # loggingException(e)
      parsed_data = {}
    end

    return parsed_data
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

    if DodontoFServer::is_webif_msgpack(parsed_data)
      logging(data, "data is webif.")
      parsed_data = DodontoFServer::reform_webif_data(data)
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

    return empty unless (File.exist?(savefile_name))

    text = ''
    open(savefile_name, 'r') do |file|
      text = file.read
    end

    return empty if (text.empty?)

    text
  end

  # DodontoFServerで定義されているCommandList
  # ['key_name', 'method_name']
  #
  # key_nameの部分はAS側で決め打ちされるので絶対不可侵.
  # キャメルケースでも、例えスペルミスがあっても今回は変更しない.
  #
  COMMAND_REFERENCE = {
      :refresh                     => :refresh,
      :getGraveyardCharacterData   => :character_data_in_graveyard,
      :resurrectCharacter          => :resurrect_character,
      :clearGraveyard              => :clear_graveyard,
      :getLoginInfo                => :login_info,
      :getPlayRoomStates           => :play_room_states,
      :getPlayRoomStatesByCount    => :play_room_states_by_count,
      :deleteImage                 => :delete_image,
      :uploadImageUrl              => :upload_image_url,
      :save                        => :save,
      :saveMap                     => :save_map,
      :saveScenario                => :save_scenario,
      :load                        => :load,
      :loadScenario                => :load_scenario,
      :getDiceBotInfos             => :dicebot_infos,
      :getBotTableInfos            => :bot_table_infos,
      :addBotTable                 => :add_bot_table,
      :changeBotTable              => :change_bot_table,
      :removeBotTable              => :remove_bot_table,
      :requestReplayDataList       => :request_replay_data_list,
      :uploadReplayData            => :upload_replay_data,
      :removeReplayData            => :remove_replay_data,
      :checkRoomStatus             => :check_room_status,
      :loginPassword               => :login_password,
      :uploadFile                  => :upload_file,
      :uploadImageData             => :upload_image_data,
      :createPlayRoom              => :create_play_room,
      :changePlayRoom              => :change_play_room,
      :removePlayRoom              => :remove_play_room,
      :removeOldPlayRoom           => :remove_old_play_room,
      :getImageTagsAndImageList    => :image_tags_and_image_list,
      :addCharacter                => :add_character,
      :getWaitingRoomInfo          => :waiting_room_info,
      :exitWaitingRoomCharacter    => :exit_waiting_room_character,
      :enterWaitingRoomCharacter   => :enter_waiting_room_character,
      :sendDiceBotChatMessage      => :send_dicebot_chat_message,
      :deleteChatLog               => :delete_chat_log,
      :sendChatMessageAll          => :send_chat_message_all,
      :undoDrawOnMap               => :undo_draw_on_map,
      :logout                      => :logout,
      :changeCharacter             => :change_character,
      :removeCharacter             => :remove_character,
      # Card Command Get
      :getMountCardInfos           => :mount_card_infos,
      :getTrushMountCardInfos      => :trash_mount_card_infos,
      # Card Command Set
      :drawTargetCard              => :draw_target_card,
      :drawTargetTrushCard         => :draw_target_trash_card,
      :drawCard                    => :draw_card,
      :addCard                     => :add_card,
      :addCardZone                 => :add_card_zone,
      :initCards                   => :init_cards,
      :returnCard                  => :return_card,
      :shuffleCards                => :shuffle_cards,
      :shuffleForNextRandomDungeon => :shuffle_next_random_dungeon,
      :dumpTrushCards              => :dump_trash_cards,
      :clearCharacterByType        => :clear_character_by_type,
      :moveCharacter               => :move_character,
      :changeMap                   => :change_map,
      :drawOnMap                   => :draw_on_map,
      :clearDrawOnMap              => :clear_draw_on_map,
      :sendChatMessage             => :send_chat_message,
      :changeRoundTime             => :change_round_time,
      :addEffect                   => :add_effect,
      :changeEffect                => :change_effect,
      :removeEffect                => :remove_effect,
      :changeImageTags             => :change_image_tags,
  }

  def execute_command
    current_command = request_data('cmd') || ''

    logging(current_command, 'commandName')

    return response_for_none_command if current_command.empty?

    #TODO 最終的にはmethod_missing内部でThrowするように修正した方が良い
    begin
      return send(DodontoFServer::COMMAND_REFERENCE[:"#{current_command}"])
    rescue
      throw Exception.new(%Q{"#{current_command.untaint}" is invalid command})
    end
  end

  def response_for_none_command
    logging 'getResponseTextWhenNoCommandName Begin'
    execute_webif_command || test_response
  end

  def execute_webif_command
    result = { 'result' => 'NG' }

    begin
      result = routing_webif_command
      logging("analyzeWebInterfaceCatches end result", result)
      set_jsonp_callback
    rescue => e
      result['result'] = e.to_s
    end

    result
  end

  def routing_webif_command
    logging "analyzeWebInterfaceCatches begin"

    @is_web_interface = true
    @is_json_result   = true

    current_command = request_data('webif') || ''
    logging(current_command, 'commandName')

    return nil if current_command.empty?

    marker = request_data('marker') || ''
    @is_add_marker = false if marker.empty?

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

    { 'result' => "command [#{current_command}] is NOT found" }
  end


  def login_on_web_interface
    text_room_index = request_data('room') || ''

    raise "プレイルーム番号(room)を指定してください" if text_room_index.empty?
    raise "プレイルーム番号(room)には半角数字のみを指定してください" unless /^\d+$/ === text_room_index

    room_index   = text_room_index.to_i
    password     = request_data('password')
    visitor_mode = true

    checked_result = check_login_password(room_index, password, visitor_mode)
    if checked_result['resultText'] != "OK"
      result['result'] = result['resultText']
      return result
    end

    init_savefiles(room_index)
  end

  def set_jsonp_callback
    callback = request_data('callback') || ''

    logging('callBack', callback)
    return if callback.empty?

    @jsonp_callback = callback
  end


  def test_response
    "「どどんとふ」の動作環境は正常に起動しています。"
  end


  def current_save_data
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
      seconds   = request_data('sec')
      save_data = chat_text_by_second(seconds)
    end

    save_data['result'] = 'OK'

    save_data
  end


  def chat_text_by_time(time)
    logging(time, 'getWebIfChatTextFromTime time')

    save_data          = {}
    @last_update_times = { 'chatMessageDataLog' => time }
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

    save_data          = {}
    @last_update_times = { 'chatMessageDataLog' => time }
    current_save_data do |targetSaveData, saveFileTypeName|
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


  def chat_color
    name = request_text_for_webif('name') || ''
    logging(name, "name")

    raise "対象ユーザー名(name)を指定してください" if name.empty?

    color = chat_color_in_save_data(name)
    raise "指定ユーザー名の発言が見つかりません" if color.nil?

    result = {
        'result' => 'OK',
        'color' => color }
  end

  def chat_color_in_save_data(name)
    seconds   = 'all'
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

  def busy_info
    json_data = {
        "loginCount"    => File.readlines($loginCountFile).join.to_i,
        "maxLoginCount" => $aboutMaxLoginCount,
        "version"       => $version,
        "result"        => 'OK',
    }
  end

  def server_info_for_webif
    result_data = {
        "max_room"             => ($saveDataMaxCount - 1),
        'isNeedCreatePassword' => (not $createPlayRoomPassword.empty?),
        'result'               => 'OK',
    }

    if request_boolean_for_webif("card", false)
      cards_infos              = cards_info.collectCardTypeAndTypeName
      result_data["cardInfos"] = cards_infos
    end

    if request_boolean_for_webif("dice", false)
      require 'diceBotInfos'
      dicebot_infos               = DiceBotInfos.new.getInfos
      result_data['diceBotInfos'] = dicebot_infos
    end

    result_data
  end

  def room_list_for_webif
    logging("getWebIfRoomList Begin")
    min_room = request_int_for_webif('min_room', 0)
    max_room = request_int_for_webif('max_room', ($saveDataMaxCount - 1))

    room_states = play_room_states_local(min_room, max_room)

    result_data = {
        "playRoomStates" => room_states,
        "result"         => 'OK',
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

    roll_result, is_secret, rand_results = dice_roll(message, game_type, false)

    message = message + roll_result
    logging(message, "diceRolled message")

    chat_data = {
        "senderName" => name,
        "message"    => message,
        "color"      => color,
        "uniqueId"   => '0',
        "channel"    => channel,
    }
    logging("sendWebIfChatText chatData", chat_data)

    send_chat_message_by_chat_data(chat_data)

    result           = {}
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
      hash[key]  = value
    end

    logging(hash, "getWebIfRequestHash result")

    hash
  end

  def send_memo_for_webif
    logging('sendWebIfAddMemo begin')

    result           = {}
    result['result'] = 'OK'

    result_context = {
        "message"   => request_text_for_webif('message', ''),
        "x"         => 0,
        "y"         => 0,
        "height"    => 1,
        "width"     => 1,
        "rotation"  => 0,
        "isPaint"   => true,
        "color"     => 16777215,
        "draggable" => true,
        "type"      => "Memo",
        "imgId"     => create_character_img_id,
    }

    logging(result_context, 'sendWebIfAddMemo jsonData')
    addResult = add_character_data([result_context]) #TODO:WAHT? addResultはここで始めて宣言されているように見える

    result
  end


  def send_add_character_for_webif
    logging("sendWebIfAddCharacter begin")

    result           = {}
    result['result'] = 'OK'

    character_data = {
        "name"        => request_text_for_webif('name'),
        "size"        => request_int_for_webif('size', 1),
        "x"           => request_int_for_webif('x', 0),
        "y"           => request_int_for_webif('y', 0),
        "initiative"  => request_number_for_webif('initiative', 0),
        "counters"    => request_hash_for_webif('counters'),
        "info"        => request_text_for_webif('info'),
        "imageName"   => image_name_for_webif('image', ".\/image\/defaultImageSet\/pawn\/pawnBlack.png"),
        "rotation"    => request_int_for_webif('rotation', 0),
        "statusAlias" => request_hash_for_webif('statusAlias'),
        "dogTag"      => request_text_for_webif('dogTag', ""),
        "draggable"   => request_boolean_for_webif("draggable", true),
        "isHide"      => request_boolean_for_webif("isHide", false),
        "type"        => "characterData",
        "imgId"       => create_character_img_id,
    }

    logging(character_data, 'sendWebIfAddCharacter jsonData')


    if character_data['name'].empty?
      result['result'] = "キャラクターの追加に失敗しました。キャラクター名が設定されていません"
      return result
    end


    add_result            = add_character_data([character_data])
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

    result           = {}
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
        failed_name = already_exist_character_in_room?(saveData, { 'name' => name })
        if failed_name
          raise "「#{name}」という名前のキャラクターはすでに存在しています"
        end
      end

      character_data['name']        = name
      character_data['size']        = request_any_for_webif(:request_int_for_webif, 'size', character_data)
      character_data['x']           = request_any_for_webif(:request_number_for_webif, 'x', character_data)
      character_data['y']           = request_any_for_webif(:request_number_for_webif, 'y', character_data)
      character_data['initiative']  = request_any_for_webif(:request_number_for_webif, 'initiative', character_data)
      character_data['counters']    = request_any_for_webif(:request_hash_for_webif, 'counters', character_data)
      character_data['info']        = request_any_for_webif(:request_text_for_webif, 'info', character_data)
      character_data['imageName']   = request_any_for_webif(:image_name_for_webif, 'image', character_data, 'imageName')
      character_data['rotation']    = request_any_for_webif(:request_int_for_webif, 'rotation', character_data)
      character_data['statusAlias'] = request_any_for_webif(:request_hash_for_webif, 'statusAlias', character_data)
      character_data['dogTag']      = request_any_for_webif(:request_text_for_webif, 'dogTag', character_data)
      character_data['draggable']   = request_any_for_webif(:request_boolean_for_webif, 'draggable', character_data)
      character_data['isHide']      = request_any_for_webif(:request_boolean_for_webif, 'isHide', character_data)
      # 'type' => 'characterData',
      # 'imgId' =>  createCharacterImgId(),

    end

  end

  def character_by_name(save_data, target_name)
    characters = characters(save_data)

    character_data = characters.find do |i|
      (i['name'] == target_name)
    end
  end


  def room_info_for_webif
    logging("getWebIfRoomInfo begin")

    result           = {}
    result['result'] = 'OK'

    save_data(@savefiles['time']) do |data|
      logging(data, "saveData")
      round_time_data   = data['roundTimeData'] || {}
      result['counter'] = data['counterNames'] || []
    end

    room_info = _room_info_for_webif
    result.merge!(room_info)

    logging(result, "getWebIfRoomInfo result")

    result
  end

  def _room_info_for_webif
    result = {}

    real_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

    save_data(real_savefile_name) do |data|
      result['roomName']   = data['playRoomName'] || ''
      result['chatTab']    = data['chatChannelNames'] || []
      result['outerImage'] = data['canUseExternalImage'] || false
      result['visit']      = data['canVisit'] || false
      result['game']       = data['gameType'] || ''
    end

    result
  end

  def set_room_info_for_webif
    logging("setWebIfRoomInfo begin")

    result           = {}
    result['result'] = 'OK'

    set_counter_names_in_room_info_webif

    real_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

    room_info = _room_info_for_webif
    change_save_data(real_savefile_name) do |saveData|
      saveData['playRoomName']        = request_any_for_webif(:request_text_for_webif, 'roomName', room_info)
      saveData['chatChannelNames']    = request_any_for_webif(:request_array_for_webif, 'chatTab', room_info)
      saveData['canUseExternalImage'] = request_any_for_webif(:request_boolean_for_webif, 'outerImage', room_info)
      saveData['canVisit']            = request_any_for_webif(:request_boolean_for_webif, 'visit', room_info)
      saveData['gameType']            = request_any_for_webif(:request_text_for_webif, 'game', room_info)
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
      saveData['roundTimeData']       ||= {}
      round_time_data                 = saveData['roundTimeData']
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
        'chatMessageDataLog'      => chat_time,
        'map'                     => request_number_for_webif('map', -1),
        'characters'              => request_number_for_webif('characters', -1),
        'time'                    => request_number_for_webif('time', -1),
        'effects'                 => request_number_for_webif('effects', -1),
        $play_room_info_type_name => request_number_for_webif('roomInfo', -1),
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

    result['roomInfo']        = save_data
    result['lastUpdateTimes'] = @last_update_times
    result['result']          = 'OK'

    logging("getWebIfRefresh End result", result)

    result
  end


  def refresh
    logging("==>Begin refresh")

    save_data = {}

    if $isMentenanceNow
      save_data["warning"] = { "key" => "canNotRefreshBecauseMentenanceNow" }
      return save_data
    end

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

    unique_id  = command_sender
    user_name  = params['name']
    is_visitor = params['isVisiter']

    login_user_info = login_user_info(user_name, unique_id, is_visitor)

    unless save_data.empty?
      save_data['lastUpdateTimes'] = @last_update_times
      save_data['refreshIndex']    = refresh_index
      save_data['loginUserInfo']   = login_user_info
    end

    if is_first_chat_refresh
      save_data['isFirstChatRefresh'] = is_first_chat_refresh
    end

    logging(save_data, "refresh end saveData")
    logging("==>End refresh")

    save_data
  end

  def login_user_info(user_name, unique_id, is_visitor)
    current_login_user_info = @savedir_info.real_savefile_name($login_user_info_file_name)
    update_login_user_info(current_login_user_info, user_name, unique_id, is_visitor)
  end


  def params
    @params || request_data('params') #TODO:FIXME 1requestにつき1インスタンスでなければ他のrequestに広がる危険性があるので後々改修の余地があり.
  end


  def refresh_routine(save_data)
    now              = Time.now
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
    current_save_data do |targetSaveData, saveFileTypeName|
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


    is_get_only     = (user_name.empty? and unique_id.empty?)
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
        data      = {
            "userName" => user_info['userName'],
            "userId"   => userId,
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
        'userName'    => user_name,
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

    @savedir_info.each_with_index(target_range, $login_user_info_file_name) do |saveFiles, index|
      next unless (target_range.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        result_list[index] = 0
        next
      end

      real_savefile_name = saveFiles.first

      login_user_info    = update_login_user_info(real_savefile_name)
      result_list[index] = login_user_info.size
    end

    result_list
  end

  def login_user_list(target_range)
    login_user_list = {}
    target_range.each { |i| login_user_list[i] = [] }

    @savedir_info.each_with_index(target_range, $login_user_info_file_name) do |saveFiles, index|
      next unless (target_range.include?(index))

      if saveFiles.size != 1
        logging("emptry room")
        #loginUserList[index] = []
        next
      end

      user_names         = []
      real_savefile_name = saveFiles.first
      login_user_info    = update_login_user_info(real_savefile_name)
      login_user_info.each do |data|
        user_names << data["userName"]
      end

      login_user_list[index] = user_names
    end

    login_user_list
  end


  def save_data_lastaccess_times(target_range)
    @savedir_info.save_data_last_access_times($save_files_name_set.values, target_range)
  end

  def save_data_lastaccess_time(file_name, room_no)
    data = @savedir_info.save_data_last_access_times([file_name], [room_no])
    time = data[room_no]
  end


  def remove_old_play_room
    all_range     = (0 .. $saveDataMaxCount)
    access_times = save_data_lastaccess_times(all_range)
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
    password          = nil
    result            = remove_play_room_by_params(target_rooms, ignore_login_user, password)
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


  def find_empty_room_number
    empty_room_number = -1

    room_number_range = (0..$saveDataMaxCount)

    room_number_range.each do |roomNumber|
      @savedir_info.dir_index(roomNumber)
      real_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

      next if (File.exist?(real_savefile_name))

      empty_room_number = roomNumber
      break
    end

    empty_room_number
  end

  def play_room_states
    logging(params, "params")

    min_room         = min_room(params)
    max_room         = max_room(params)
    play_room_states = play_room_states_local(min_room, max_room)

    result = {
        "min_room"       => min_room,
        "max_room"       => max_room,
        "playRoomStates" => play_room_states,
    }

    logging(result, "getPlayRoomStatesLocal result")

    result
  end

  def play_room_states_local(min_room, max_room)
    room_number_range = (min_room .. max_room)
    play_room_states  = []

    room_number_range.each do |roomNo|

      @savedir_info.dir_index(roomNo)

      play_room_state = play_room_state(roomNo)
      next if (play_room_state.nil?)

      play_room_states << play_room_state
    end

    play_room_states
  end

  def play_room_state(room_no)

    # playRoomState = nil
    play_room_state                      = {}
    play_room_state['passwordLockState'] = false
    play_room_state['index']             = sprintf("%3d", room_no)
    play_room_state['playRoomName']      = "（空き部屋）"
    play_room_state['lastUpdateTime']    = ""
    play_room_state['canVisit']          = false
    play_room_state['gameType']          = ''
    play_room_state['login_users']       = []

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
    play_room_info_file = @savedir_info.real_savefile_name($play_room_info_file_name)

    return play_room_state unless (File.exist?(play_room_info_file))

    play_room_data = nil
    save_data(play_room_info_file) do |playRoomDataTmp|
      play_room_data = playRoomDataTmp
    end
    logging(play_room_data, "playRoomData")

    return play_room_state if (play_room_data.empty?)

    play_room_name      = play_room_name(play_room_data, room_no)
    password_lock_state = (not play_room_data['playRoomChangedPassword'].nil?)
    can_visit           = play_room_data['canVisit']
    game_type           = play_room_data['gameType']
    timestamp           = save_data_lastaccess_time($save_files_name_set['chatMessageDataLog'], room_no)

    time_display = ""
    unless timestamp.nil?
      time_display = "#{timestamp.strftime('%Y/%m/%d %H:%M:%S')}"
    end

    login_users = login_user_names

    play_room_state['passwordLockState'] = password_lock_state
    play_room_state['playRoomName']      = play_room_name
    play_room_state['lastUpdateTime']    = time_display
    play_room_state['canVisit']          = can_visit
    play_room_state['gameType']          = game_type
    play_room_state['loginUsers']        = login_users

    play_room_state
  end

  def login_user_names
    user_names = []

    real_savefile_name = @savedir_info.real_savefile_name($login_user_info_file_name)
    logging(real_savefile_name, "getLoginUserNames real_savefile_name")

    unless File.exist?(real_savefile_name)
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
    game_info     = dicebot_infos.find { |i| i["gameType"] == game_type }

    return '--' if (game_info.nil?)

    game_info["name"]
  end


  def play_room_states_by_count
    logging(params, "params")

    min_room         = min_room(params)
    count            = params["count"]
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

      @savedir_info.dir_index(roomNo)

      play_room_state = play_room_state(roomNo)
      next if (play_room_state.nil?)

      play_room_states << play_room_state
    end

    play_room_states
  end


  def all_login_count
    room_number_range     = (0 .. $saveDataMaxCount)
    login_user_count_list = login_user_count_list(room_number_range)

    total     = 0
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
    game_type_list    = getGameTypeList(room_number_range)

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
      famous_games << { "gameType" => game_type, "count" => count }
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

  def login_info
    logging("getLoginInfo begin")

    unique_id = params['uniqueId']
    unique_id ||= create_unique_id

    all_login_count, login_user_count_list = all_login_count
    write_all_login_info(all_login_count)

    card_infos = cards_info.collectCardTypeAndTypeName

    result = {
        "loginMessage"               => login_message,
        "cardInfos"                  => card_infos,
        "isDiceBotOn"                => $isDiceBotOn,
        "uniqueId"                   => unique_id,
        "refreshTimeout"             => $refreshTimeout,
        "refreshInterval"            => refresh_interval,
        "isCommet"                   => $isCommet,
        "version"                    => $version,
        "playRoomMaxNumber"          => ($saveDataMaxCount - 1),
        "warning"                    => login_warning,
        "playRoomGetRangeMax"        => $playRoomGetRangeMax,
        "allLoginCount"              => all_login_count.to_i,
        "limitLoginCount"            => $limitLoginCount,
        "loginUserCountList"         => login_user_count_list,
        "maxLoginCount"              => $aboutMaxLoginCount.to_i,
        "skinImage"                  => $skinImage,
        "isPaformanceMonitor"        => $isPaformanceMonitor,
        "fps"                        => $fps,
        "loginTimeLimitSecond"       => $loginTimeLimitSecond,
        "removeOldPlayRoomLimitDays" => $removeOldPlayRoomLimitDays,
        "canTalk"                    => $canTalk,
        "retryCountLimit"            => $retryCountLimit,
        "imageUploadDirInfo"         => { $localUploadDirMarker => $imageUploadDir },
        "mapMaxWidth"                => $mapMaxWidth,
        "mapMaxHeigth"               => $mapMaxHeigth,
        'diceBotInfos'               => dicebot_infos,
        'isNeedCreatePassword'       => (not $createPlayRoomPassword.empty?),
        'defaultUserNames'           => $defaultUserNames,
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
    lockfile      = real_savefile_lock_readonly(savefile_name)

    lockfile.lock do
      File.open(savefile_name, "w+") do |file|
        file.write(text.toutf8)
      end
    end
  end


  def login_warning
    unless File.exist?(small_image_dir)
      return {
          "key"    => "noSmallImageDir",
          "params" => [small_image_dir],
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
    message = ""
    message << login_message_header
    message << login_message_history_part
    message
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

  def dicebot_infos
    logging("getDiceBotInfos Begin")

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

  def dicebot_prefix_one(bot_info, command_info)
    logging(bot_info, "botInfo")
    return if (bot_info.nil?) #TODO:FIXME この条件式の戻り値はnull.かつこの条件が真である場合も以下のif条件は正常に動作し、同様にnullを返すので不要とおもわれる.

    prefixs = bot_info["prefixs"]
    return if (prefixs.nil?)

    prefixs << command_info["command"]
  end

  def game_command_infos
    logging('getGameCommandInfos Begin')

    if @savedir_info.dir_index == -1
      logging('getGameCommandInfos room is -1, so END')

      return []
    end

    require 'cgiDiceBot.rb'
    bot = CgiDiceBot.new
    dir = dicebot_extra_table_dir_name
    logging(dir, 'dir')

    command_infos = bot.getGameCommandInfos(dir, @dicebot_table_prefix)
    logging(command_infos, "getGameCommandInfos End commandInfos")

    command_infos
  end


  def create_dir(play_room_index)
    @savedir_info.dir_index(play_room_index)
    @savedir_info.create_dir
  end

  def create_play_room
    logging('createPlayRoom begin')

    result_text     = "OK"
    play_room_index = -1
    begin
      logging(params, "params")

      check_create_play_room_password(params['createPassword'])

      play_room_name         = params['playRoomName']
      play_room_password     = params['playRoomPassword']
      chat_channel_names     = params['chatChannelNames']
      can_use_external_image = params['canUseExternalImage']

      can_visit       = params['canVisit']
      play_room_index = params['playRoomIndex']

      if play_room_index == -1
        play_room_index = find_empty_room_number
        raise Exception.new("noEmptyPlayRoom") if (play_room_index == -1)

        logging(play_room_index, "findEmptyRoomNumber playRoomIndex")
      end

      logging(play_room_name, 'playRoomName')
      logging('playRoomPassword is get')
      logging(play_room_index, 'playRoomIndex')

      init_savefiles(play_room_index)
      check_set_password(play_room_password, play_room_index)

      logging("@saveDirInfo.removeSaveDir(playRoomIndex) Begin")
      @savedir_info.remove_dir(play_room_index)
      logging("@saveDirInfo.removeSaveDir(playRoomIndex) End")

      create_dir(play_room_index)

      play_room_changed_password = changed_password(play_room_password)
      logging(play_room_changed_password, 'playRoomChangedPassword')

      view_states = params['viewStates']
      logging("viewStates", view_states)

      real_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

      change_save_data(real_savefile_name) do |saveData|
        saveData['playRoomName']            = play_room_name
        saveData['playRoomChangedPassword'] = play_room_changed_password
        saveData['chatChannelNames']        = chat_channel_names
        saveData['canUseExternalImage']     = can_use_external_image
        saveData['canVisit']                = can_visit
        saveData['gameType']                = params['gameType']

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
        "resultText"    => result_text,
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
        "message"    => "＝＝＝＝＝＝＝　プレイルーム　【　No.　#{room_no}　】　へようこそ！　＝＝＝＝＝＝＝",
        "color"      => "cc0066",
        "uniqueId"   => '0',
        "channel"    => 0,
    }

    send_chat_message_by_chat_data(chat_data)
  end


  def add_view_states_to_savedata(save_data, view_states)
    view_states['key']         = Time.now.to_f.to_s
    save_data['viewStateInfo'] = view_states
  end

  def changed_password(pass)
    return nil if (pass.empty?)

    salt = [rand(64), rand(64)].pack("C*").tr("\x00-\x3f", "A-Za-z0-9./")
    pass.crypt(salt)
  end

  def change_play_room
    logging "changePlayRoom begin"

    result_text = "OK"

    begin
      logging(params, "params")

      play_room_password = params['playRoomPassword']
      check_set_password(play_room_password)

      play_room_changed_password = changed_password(play_room_password)
      logging('playRoomPassword is get')

      view_states = params['viewStates']
      logging("viewStates", view_states)

      real_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

      change_save_data(real_savefile_name) do |saveData|
        saveData['playRoomName']            = params['playRoomName']
        saveData['playRoomChangedPassword'] = play_room_changed_password
        saveData['chatChannelNames']        = params['chatChannelNames']
        saveData['canUseExternalImage']     = params['canUseExternalImage']
        saveData['canVisit']                = params['canVisit']
        saveData['backgroundImage']         = params['backgroundImage']
        saveData['gameType']                = params['gameType']

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
      room_number = @savedir_info.dir_index
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
    last_access_time  = last_access_times[room_number]
    logging(last_access_time, "lastAccessTime")

    unless last_access_time.nil?
      now         = Time.now
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

    @savedir_info.dir_index(room_number)
    real_savefile_name   = @savedir_info.real_savefile_name($play_room_info_file_name)
    exist_play_room_info = (File.exist?(real_savefile_name))

    return true unless (exist_play_room_info)

    matched = false
    save_data(real_savefile_name) do |saveData|
      changed_password = saveData['playRoomChangedPassword']
      matched          = password_match?(password, changed_password)
    end

    matched
  end


  def remove_play_room

    room_numbers      = params['roomNumbers']
    ignore_login_user = params['ignoreLoginUser']
    password          = params['password']
    password          ||= ""

    remove_play_room_by_params(room_numbers, ignore_login_user, password)
  end

  def remove_play_room_by_params(room_numbers, ignore_login_user, password)
    logging(ignore_login_user, 'removePlayRoomByParams Begin ignoreLoginUser')

    deleted_room_numbers    = []
    error_messages          = []
    password_room_numbers   = []
    ask_delete_room_numbers = []

    room_numbers.each do |room_number|
      room_number = room_number.to_i
      logging(room_number, 'roomNumber')

      result_text = check_remove_play_room(room_number, ignore_login_user, password)
      logging(result_text, "checkRemovePlayRoom resultText")

      case result_text
        when "OK"
          @savedir_info.remove_dir(room_number)
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
        "deletedRoomNumbers"   => deleted_room_numbers,
        "askDeleteRoomNumbers" => ask_delete_room_numbers,
        "passwordRoomNumbers"  => password_room_numbers,
        "errorMessages"        => error_messages,
    }
    logging(result, 'result')

    result
  end

  def remove_local_space_dir(room_number)
    dir = room_local_space_dir_name_by_room_no(room_number)
    rmdir(dir)
  end

  def real_savefile_name(file_name)
    @savedir_info.real_savefile_name($saveFileTempName)
  end

  def save_scenario
    logging("saveScenario begin")
    dir = room_local_space_dir_name
    make_dir(dir)

    @save_scenario_base_url      = params['baseUrl']
    chat_palette_savedata_string = params['chatPaletteSaveData']

    all_save_data = savedata_all_for_scenario
    all_save_data = move_all_images_to_dir(dir, all_save_data)
    make_chat_pallet_savefile(dir, chat_palette_savedata_string)
    make_scenario_default_savefile(dir, all_save_data)

    remove_old_scenario_file(dir)
    base_name     = get_new_savefile_base_name(@full_backup_base_name)
    scenario_file = make_scenario_file(dir, base_name)

    result                 = {}
    result['result']       = "OK"
    result["saveFileName"] = scenario_file

    logging(result, "saveScenario result")
    result
  end

  def savedata_all_for_scenario
    select_types = $save_files_name_set.keys
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
    map_data = load_data(all_savedata, 'map', 'mapData', {})
    image    = map_data['imageSource']

    change_file_place(image, dir)
  end

  def move_effects_image(dir, all_savedata)
    effects = load_data(all_savedata, 'effects', 'effects', [])

    effects.each do |effect|
      image = effect['source']
      change_file_place(image, dir)
    end
  end

  def move_character_images(dir, all_savedata)
    characters = load_data(all_savedata, 'characters', 'characters', [])
    move_character_images_from_characters(dir, characters)

    characters = load_data(all_savedata, 'characters', 'graveyard', [])
    move_character_images_from_characters(dir, characters)

    characters = load_data(all_savedata, 'characters', 'waitingRoom', [])
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
    from_file_name       ||= from

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

    File.open($scenario_default_chat_pallete, "a+") do |file|
      file.write(chat_palette_savedata_string)
    end

    FileUtils.cd(current_dir)
    logging("makeChatPalletSaveFile End")
  end

  def make_scenario_default_savefile(dir, all_savedata)
    logging("makeScenariDefaultSaveFile Begin")
    logging(dir, "makeScenariDefaultSaveFile dir")

    extension = "sav"
    result    = save_select_files_from_all_savedata(all_savedata, extension)

    from = result["saveFileName"]
    to   = File.join(dir, $scenario_default_savedata)

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
    tgz           = Zlib::GzipWriter.new(File.open(scenario_file, 'wb'))

    file_names = Dir.glob('*')
    file_names = file_names.collect { |i| i.untaint }

    file_names.delete_if { |i| i == scenario_file }

    Archive::Tar::Minitar.pack(file_names, tgz)

    FileUtils.cd(current_dir)

    File.join(dir, scenario_file)
  end


  def save
    is_add_playroom_info = true
    extension            = request_data('extension')
    save_select_files($save_files_name_set.keys, extension, is_add_playroom_info)
  end

  def save_map
    extension    = request_data('extension')
    select_types = ['map', 'characters']
    save_select_files(select_types, extension)
  end


  def save_select_files(select_types, extension, is_add_playroom_info = false)
    all_savedata = get_select_files_data(select_types, is_add_playroom_info)
    save_select_files_from_all_savedata(all_savedata, extension)
  end

  def save_select_files_from_all_savedata(all_savedata, extension)
    result           = {}
    result["result"] = "unknown error"

    if all_savedata.empty?
      result["result"] = "no save data"
      return result
    end

    delete_old_savefile

    save_data                = {}
    save_data['saveDataAll'] = all_savedata

    text          = DodontoFServer::build_json(save_data)
    savefile_name = get_new_savefile_name(extension)
    create_savefile(savefile_name, text)

    result["result"]       = "OK"
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
    current_save_data do |targetSaveData, saveFileTypeName|
      all_savedata[saveFileTypeName] = targetSaveData
      logging(saveFileTypeName, "saveFileTypeName in save")
    end

    if is_add_playroom_info
      true_savefile_name                            = @savedir_info.real_savefile_name($play_room_info_file_name)
      @last_update_times[$play_room_info_type_name] = 0
      if savefile_changed?(0, true_savefile_name)
        all_savedata[$play_room_info_type_name] = load_savefile($play_room_info_type_name, true_savefile_name)
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
    base_name     = get_new_savefile_base_name("DodontoF")
    savefile_name = base_name + ".#{extension}"
    file_join($saveDataTempDir, savefile_name).untaint
  end

  def get_new_savefile_base_name(prefix)
    now       = Time.now
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

    change_save_data($save_file_names) do |saveData|
      exist_file_names = saveData["fileNames"]
      exist_file_names ||= []
      logging(exist_file_names, 'existSaveFileNames')

      regexp = /DodontoF_[\d_]+.sav/

      delete_targets = []

      exist_file_names.each do |saveFileName|
        logging(saveFileName, 'saveFileName')
        next unless (regexp === saveFileName)

        created_time = savefile_timestamp(saveFileName)
        now          = Time.now.to_i
        diff         = (now - created_time)
        logging(diff, "createdTime diff")
        next if (diff < $oldSaveFileDelteSeconds)

        begin
          delete_file(saveFileName)
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


  def check_room_status
    delete_old_upload_file

    check_room_status_data = params
    logging(check_room_status_data, 'checkRoomStatusData')

    room_number = check_room_status_data['roomNumber']
    logging(room_number, 'roomNumber')

    @savedir_info.dir_index(room_number)

    is_maintenance_on      = false
    is_welcome_message_on  = $isWelcomeMessageOn
    play_room_name         = ''
    chat_channel_names     = nil
    can_use_external_image = false
    can_visit              = false
    is_password_locked     = false
    true_savefile_name     = @savedir_info.real_savefile_name($play_room_info_file_name)
    is_exist_playroom_info = (File.exist?(true_savefile_name))

    if is_exist_playroom_info
      save_data(true_savefile_name) do |saveData|
        play_room_name         = play_room_name(saveData, room_number)
        changed_password       = saveData['playRoomChangedPassword']
        chat_channel_names     = saveData['chatChannelNames']
        can_use_external_image = saveData['canUseExternalImage']
        can_visit              = saveData['canVisit']
        unless changed_password.nil?
          is_password_locked = true
        end
      end
    end

    unless $mentenanceModePassword.nil?
      if check_room_status_data["adminPassword"] == $mentenanceModePassword
        is_password_locked    = false
        is_welcome_message_on = false
        is_maintenance_on     = true
      end
    end

    logging("isPasswordLocked", is_password_locked)

    result = {
        'isRoomExist'         => is_exist_playroom_info,
        'roomName'            => play_room_name,
        'roomNumber'          => room_number,
        'chatChannelNames'    => chat_channel_names,
        'canUseExternalImage' => can_use_external_image,
        'canVisit'            => can_visit,
        'isPasswordLocked'    => is_password_locked,
        'isMentenanceModeOn'  => is_maintenance_on,
        'isWelcomeMessageOn'  => is_welcome_message_on,
    }

    logging(result, "checkRoomStatus End result")

    result
  end

  def login_password
    login_data = params
    logging(login_data, 'loginData')

    room_number  = login_data['roomNumber']
    password     = login_data['password']
    visitor_mode = login_data['visiterMode']

    check_login_password(room_number, password, visitor_mode)
  end

  def check_login_password(room_number, password, visitor_mode)
    logging("checkLoginPassword roomNumber", room_number)
    @savedir_info.dir_index(room_number)
    dir_name = @savedir_info.data_dir_path

    result = {
        'resultText'  => '',
        'visiterMode' => false,
        'roomNumber'  => room_number,
    }

    is_room_exist = (File.exist?(dir_name))

    unless is_room_exist
      result['resultText'] = "プレイルームNo.#{room_number}は作成されていません"
      return result
    end


    true_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)

    save_data(true_savefile_name) do |saveData|
      can_visit = saveData['canVisit']
      if can_visit and visitor_mode
        result['resultText']  = "OK"
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


  def logout
    logout_data = params
    logging(logout_data, 'logoutData')

    unique_id = logout_data['uniqueId']
    logging(unique_id, 'uniqueId')

    true_savefile_name = @savedir_info.real_savefile_name($login_user_info_file_name)
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

    return nil
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


  def bot_table_infos
    logging("getBotTableInfos Begin")
    result = {
        "resultText" => "OK",
    }

    dir                  = dicebot_extra_table_dir_name
    result["tableInfos"] = get_bot_table_infos_from_dir(dir)

    logging(result, "result")
    logging("getBotTableInfos End")
    result
  end

  def get_bot_table_infos_from_dir(dir)
    logging(dir, 'getBotTableInfosFromDir dir')

    require 'TableFileData'

    is_load_common_table = false
    table_file_data      = TableFileData.new(is_load_common_table)
    table_file_data.setDir(dir, @dicebot_table_prefix)
    table_infos = table_file_data.getAllTableInfo

    logging(table_infos, "getBotTableInfosFromDir tableInfos")
    table_infos.sort! { |a, b| a["command"].to_i <=> b["command"].to_i }

    logging(table_infos, 'getBotTableInfosFromDir result tableInfos')

    table_infos
  end


  def add_bot_table
    result               = {}
    result['resultText'] = add_bot_table_main

    if result['resultText'] != "OK"
      return result
    end

    logging("addBotTableMain called")

    result = bot_table_infos
    logging(result, "addBotTable result")

    result
  end

  def add_bot_table_main
    logging("addBotTableMain Begin")

    dir = dicebot_extra_table_dir_name
    make_dir(dir)

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


  def change_bot_table
    result               = {}
    result['resultText'] = change_bot_table_main

    if result['resultText'] != "OK"
      return result
    end

    bot_table_infos
  end

  def change_bot_table_main
    logging("changeBotTableMain Begin")

    dir = dicebot_extra_table_dir_name

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


  def remove_bot_table
    remove_bot_table_main
    bot_table_infos
  end

  def remove_bot_table_main
    logging("removeBotTableMain Begin")

    command = params["command"]

    dir = dicebot_extra_table_dir_name

    require 'TableFileData'

    is_load_common_table = false
    table_file_data      = TableFileData.new(is_load_common_table)
    table_file_data.setDir(dir, @dicebot_table_prefix)
    table_infos = table_file_data.getAllTableInfo

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


  def request_replay_data_list
    logging("requestReplayDataList begin")
    result = {
        "resultText" => "OK",
    }

    result["replayDataList"] = get_replay_data_list #[{"title"=>x, "url"=>y}]

    logging(result, "result")
    logging("requestReplayDataList end")
    result
  end

  def upload_replay_data
    upload_base_file($replayDataUploadDir, $UPLOAD_REPALY_DATA_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|
      logging("uploadReplayData yield Begin")

      own_url    = params['ownUrl']
      replay_url = own_url + "?replay=" + CGI.escape(fileNameFullPath)

      replay_data_name = params['replayDataName']
      replay_data_info = set_replay_data_info(fileNameFullPath, replay_data_name, replay_url)

      result["replayDataInfo"] = replay_data_info
      result["replayDataList"] = get_replay_data_list #[{"title"=>x, "url"=>y}]

      logging("uploadReplayData yield End")
    end

  end

  def get_replay_data_list
    replay_data_list = nil

    save_data(get_replay_data_info_file_name) do |saveData|
      replay_data_list = saveData['replayDataList']
    end

    replay_data_list ||= []
  end

  def get_replay_data_info_file_name
    info_file_name = file_join($replayDataUploadDir, 'replayDataInfo.json')
  end


  #image_info_file_name() ) do |saveData|
  def set_replay_data_info(file_name, title, url)

    replay_data_info = {
        "fileName" => file_name,
        "title"    => title,
        "url"      => url,
    }

    change_save_data(get_replay_data_info_file_name) do |saveData|
      saveData['replayDataList'] ||= []
      replay_data_list           = saveData['replayDataList']
      replay_data_list << replay_data_info
    end

    replay_data_info
  end


  def remove_replay_data
    logging("removeReplayData begin")

    result = {
        "resultText" => "NG",
    }

    begin
      replay_data = params

      logging(replay_data, "replayData")

      replay_data_list = []
      change_save_data(get_replay_data_info_file_name) do |saveData|
        saveData['replayDataList'] ||= []
        replay_data_list           = saveData['replayDataList']

        replay_data_list.delete_if do |i|
          if (i['url'] == replay_data['url']) and (i['title'] == replay_data['title'])
            delete_file(i['fileName'])
            true
          else
            false
          end
        end
      end

      logging("removeReplayData replayDataList", replay_data_list)

      result = request_replay_data_list
    rescue => e
      result["resultText"] = e.to_s
      logging_exception(e)
    end

    result
  end


  def upload_file
    upload_base_file($fileUploadDir, $UPLOAD_FILE_MAX_SIZE) do |fileNameFullPath, fileNameOriginal, result|

      delete_old_upload_file

      base_url = params['baseUrl']
      logging(base_url, "baseUrl")

      file_upload_url = base_url + fileNameFullPath

      result["uploadFileInfo"] = {
          "fileName"      => fileNameOriginal,
          "fileUploadUrl" => file_upload_url,
      }
    end
  end


  def delete_old_upload_file
    delete_old_file($fileUploadDir, $uploadFileTimeLimitSeconds, File.join($fileUploadDir, "dummy.txt"))
  end

  def delete_old_file(save_dir, limit_sec, exclude_file_name = nil)
    begin
      limit_time = (Time.now.to_i - limit_sec)
      file_names = Dir.glob(File.join(save_dir, "*"))
      file_names.delete_if { |i| i == exclude_file_name }

      file_names.each do |file_name|
        file_name = file_name.untaint
        timestamp = File.mtime(file_name).to_i
        next if (timestamp >= limit_time)

        File.delete(file_name)
      end
    rescue => e
      logging_exception(e)
    end
  end


  def upload_base_file(file_upload_dir, max_size, is_rename = true)
    logging("uploadFile() Begin")

    result = {
        "resultText" => "NG",
    }

    begin

      unless File.exist?(file_upload_dir)
        result["resultText"] = "#{file_upload_dir}が存在しないためアップロードに失敗しました。"
        return result
      end

      file_data = params['fileData']

      check_result = check_filesize_on_mb(file_data, max_size)
      if check_result != ""
        result["resultText"] = check_result
        return result
      end

      org_file_name = params['fileName'].toutf8

      file_name = org_file_name
      if is_rename
        file_name = new_file_name(org_file_name)
      end

      full_path = file_join(file_upload_dir, file_name).untaint
      logging(full_path, "fileNameFullPath")

      yield(full_path, org_file_name, result)

      open(full_path, "w+") do |file|
        file.binmode
        file.write(file_data)
      end
      File.chmod(0666, full_path)

      result["resultText"] = "OK"
    rescue => e
      logging(e, "error")
      result["resultText"] = e.to_s
    end

    logging(result, "load result")
    logging("uploadFile() End")

    result
  end


  def load_scenario
    logging("loadScenario() Begin")
    check_load

    set_record_empty

    file_upload_dir = room_local_space_dir_name

    clear_dir(file_upload_dir)
    make_dir(file_upload_dir)

    file_max_size = $scenarioDataMaxSize # Mbyte
    scenario_file = nil
    is_rename     = false

    result = upload_base_file(file_upload_dir, file_max_size, is_rename) do |fileNameFullPath, fileNameOriginal, result|
      scenario_file = fileNameFullPath
    end

    logging(result, "uploadFileBase result")

    unless result["resultText"] == 'OK'
      return result
    end

    extend_savedata(scenario_file, file_upload_dir)

    chat_palette_savedata         = load_scenario_default_info(file_upload_dir)
    result['chatPaletteSaveData'] = chat_palette_savedata

    logging(result, 'loadScenario result')

    result
  end

  def clear_dir(dir)
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

  def extend_savedata(scenario_file, file_upload_dir)
    logging(scenario_file, 'scenarioFile')
    logging(file_upload_dir, 'fileUploadDir')

    require 'zlib'
    require 'archive/tar/minitar'

    read_scenario_tar(scenario_file) do |tar|
      logging("begin read scenario tar file")

      Archive::Tar::Minitar.unpackWithCheck(tar, file_upload_dir) do |fileName, isDirectory|
        check_unpack_file(fileName, isDirectory)
      end
    end

    File.delete(scenario_file)

    logging("archive extend !")
  end

  def read_scenario_tar(scenario_file)

    begin
      File.open(scenario_file, 'rb') do |file|
        tar = file
        tar = Zlib::GzipReader.new(file)

        logging("scenarioFile is gzip")
        yield(tar)

      end
    rescue
      File.open(scenario_file, 'rb') do |file|
        tar = file

        logging("scenarioFile is tar")
        yield(tar)

      end
    end
  end


  #直下のファイルで許容する拡張子の場合かをチェック
  def check_unpack_file(file_name, is_directory)
    logging(file_name, 'checkUnpackFile fileName')
    logging(directory?, 'checkUnpackFile isDirectory')

    if is_directory
      logging('isDirectory!')
      return false
    end

    result = allowed_unpack_file?(file_name)
    logging(result, 'checkUnpackFile result')

    result
  end

  def allowed_unpack_file?(file_name)

    if /\// =~ file_name
      loggingForce(file_name, 'NG! checkUnpackFile /\// paturn')
      return false
    end

    if allowed_file_ext?(file_name)
      return true
    end

    loggingForce(file_name, 'NG! checkUnpackFile else paturn')

    false
  end

  def allowed_file_ext?(file_name)
    ext_name = allowed_file_ext_name(file_name)
    (not ext_name.nil?)
  end

  def allowed_file_ext_name(file_name)
    rule = /\.(jpg|jpeg|gif|png|bmp|pdf|doc|txt|html|htm|xls|rtf|zip|lzh|rar|swf|flv|avi|mp4|mp3|wmv|wav|sav|cpd)$/

    return nil unless (rule === file_name)

    ext_name = "." + $1
  end

  def room_local_space_dir_name
    room_no = @savedir_info.dir_index
    room_local_space_dir_name_by_room_no(room_no)
  end

  def room_local_space_dir_name_by_room_no(room_no)
    dir = File.join($imageUploadDir, "room_#{room_no}")
  end

  def make_dir(dir)
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
    SaveDirInfo.remove_dir(dir)
  end

  $scenario_default_savedata     = 'default.sav'
  $scenario_default_chat_pallete = 'default.cpd'

  def load_scenario_default_info(dir)
    load_scenario_default_savedata(dir)
    chat_palette_savedata = load_scenario_default_chat_pallete(dir)

    chat_palette_savedata
  end

  def load_scenario_default_savedata(dir)
    logging('loadScenarioDefaultSaveData begin')
    save_file = File.join(dir, $scenario_default_savedata)

    unless File.exist?(save_file)
      logging(save_file, 'saveFile is NOT exist')
      return
    end

    json_data_string = File.readlines(save_file).join
    load_from_json_data_string(json_data_string)

    logging('loadScenarioDefaultSaveData end')
  end


  def load_scenario_default_chat_pallete(dir)
    file = File.join(dir, $scenario_default_chat_pallete)
    logging(file, 'loadScenarioDefaultChatPallete file')

    return nil unless (File.exist?(file))

    buffer = File.readlines(file).join
    logging(buffer, 'loadScenarioDefaultChatPallete buffer')

    buffer
  end


  def load
    logging("saveData load() Begin")

    result = {}

    begin
      check_load

      set_record_empty

      logging(params, 'load params')

      json_data_string = params['fileData']
      logging(json_data_string, 'jsonDataString')

      result = load_from_json_data_string(json_data_string)
    rescue => e
      result["resultText"] = e.to_s
    end

    logging(result, "load result")

    result
  end


  def check_load
    room_number = @savedir_info.dir_index

    if $unloadablePlayRoomNumbers.include?(room_number)
      raise "unloadablePlayRoomNumber"
    end
  end


  def change_load_text(text)
    text = change_text_in_local_space_dir(text)
  end

  def change_text_in_local_space_dir(text)
    #プレイルームにローカルなファイルを置く場合の特殊処理用ディレクトリ名変換
    dir           = room_local_space_dir_name
    dir_json_text = JsonBuilder.new.build(dir)
    changed_dir   = dir_json_text[2...-2]

    logging(changed_dir, 'localSpace name')

    text = text.gsub($imageUploadDirMarker, changed_dir)
  end


  def load_from_json_data_string(json_data_string)
    json_data_string = change_load_text(json_data_string)

    json_data = DodontoFServer::parse_json(json_data_string)
    load_from_json_data(json_data)
  end

  def load_from_json_data(json_data)
    logging(json_data, 'loadFromJsonData jsonData')

    save_data_all = all_savedata_in_savedata(json_data)

    remove_character_data_list = params['removeCharacterDataList']
    if remove_character_data_list != nil
      remove_character_by_remove_character_data_list(remove_character_data_list)
    end

    targets = params['targets']
    logging(targets, "targets")

    if targets.nil?
      logging("loadSaveFileDataAll(saveDataAll)")
      load_savefile_all_data(save_data_all)
    else
      logging("loadSaveFileDataFilterByTargets(saveDataAll, targets)")
      load_savefile_data_filter_targets(save_data_all, targets)
    end

    result = {
        "resultText" => "OK"
    }

    logging(result, "loadFromJsonData result")

    result
  end

  def all_savedata_in_savedata(json_data)
    json_data['saveDataAll']
  end

  def load_data(all_save_data, file_type, key, default_value)
    savefile_data = all_save_data[file_type]
    return default_value if (savefile_data.nil?)

    data = savefile_data[key]
    return default_value if (data.nil?)

    data.clone
  end

  def load_character_data_list(all_save_data, type)
    character_data_list = load_data(all_save_data, 'characters', 'characters', [])
    logging(character_data_list, "characterDataList")

    character_data_list = character_data_list.delete_if { |i| (i["type"] != type) }
    add_character_data(character_data_list)
  end

  def load_savefile_data_filter_targets(all_save_data, targets)
    targets.each do |target|
      logging(target, 'loadSaveFileDataFilterByTargets each target')

      case target
        when "map"
          map_data = load_data(all_save_data, 'map', 'mapData', {})
          change_map_savedata(map_data)
        when "characterData", "mapMask", "mapMarker", "magicRangeMarker", "magicRangeMarkerDD4th", "Memo", card_type
          load_character_data_list(all_save_data, target)
        when "characterWaitingRoom"
          logging("characterWaitingRoom called")
          waiting_room = load_data(all_save_data, 'characters', 'waitingRoom', [])
          set_waiting_room_info(waiting_room)
        when "standingGraphicInfos"
          effects = load_data(all_save_data, 'effects', 'effects', [])
          effects = effects.delete_if { |i| (i["type"] != target) }
          logging(effects, "standingGraphicInfos effects");
          add_effect_data(effects)
        when "cutIn"
          effects = load_data(all_save_data, 'effects', 'effects', [])
          effects = effects.delete_if { |i| (i["type"] != nil) }
          add_effect_data(effects)
        when "initiative"
          round_time_data = load_data(all_save_data, 'time', 'roundTimeData', {})
          change_initiative_data(round_time_data)
        else
          loggingForce(target, "invalid load target type")
      end
    end
  end

  def load_savefile_all_data(all_save_data)
    logging("loadSaveFileDataAll(saveDataAll) begin")

    @savefiles.each do |fileTypeName, trueSaveFileName|
      logging(fileTypeName, "fileTypeName")
      logging(trueSaveFileName, "real_savefile_name")

      save_data_type = all_save_data[fileTypeName]
      save_data_type ||= {}
      logging(save_data_type, "saveDataForType")

      load_savefile_data_each_type(fileTypeName, trueSaveFileName, save_data_type)
    end

    if all_save_data.include?($play_room_info_type_name)
      real_save_file_name = @savedir_info.real_savefile_name($play_room_info_file_name)
      save_data_type      = all_save_data[$play_room_info_type_name]
      load_savefile_data_each_type($play_room_info_type_name, real_save_file_name, save_data_type)
    end

    logging("loadSaveFileDataAll(saveDataAll) end")
  end


  def load_savefile_data_each_type(file_type_name, real_savefile_name, save_data_type)

    change_save_data(real_savefile_name) do |saveDataCurrent|
      logging(saveDataCurrent, "before saveDataCurrent")
      saveDataCurrent.clear

      save_data_type.each do |key, value|
        logging(key, "saveDataForType.each key")
        logging(value, "saveDataForType.each value")
        saveDataCurrent[key] = value
      end
      logging(saveDataCurrent, "after saveDataCurrent")
    end

  end


  def small_image_dir
    file_join($imageUploadDir, "smallImages")
  end

  def save_small_image(small_image_Data, file_base_name, upload_image_file_name)
    logging("saveSmallImage begin")
    logging(file_base_name, "imageFileNameBase")
    logging(upload_image_file_name, "uploadImageFileName")

    upload_file_full_path = file_join(small_image_dir, file_base_name)
    upload_file_full_path += ".png"
    upload_file_full_path.untaint
    logging(upload_file_full_path, "uploadSmallImageFileName")

    open(upload_file_full_path, "wb+") do |file|
      file.write(small_image_Data)
    end
    logging("small image create successed.")

    tag_info = params['tagInfo']
    logging(tag_info, "uploadImageData tagInfo")

    tag_info["smallImage"] = upload_file_full_path
    logging(tag_info, "uploadImageData tagInfo smallImage url added")

    marge_tag_info(tag_info, upload_image_file_name)
    logging(tag_info, "saveSmallImage margeTagInfo tagInfo")
    change_image_tags_local(upload_image_file_name, tag_info)

    logging("saveSmallImage end")
  end

  def marge_tag_info(tag_info, source)
    logging(source, "margeTagInfo source")
    old_tag_info = image_tags[source]
    logging(old_tag_info, "margeTagInfo tagInfo_old")
    return if (old_tag_info.nil?)

    old_tag_info.keys.each do |key|
      tag_info[key] = old_tag_info[key]
    end

    logging(tag_info, "margeTagInfo tagInfo")
  end

  def upload_image_data
    logging "uploadImageData load Begin"

    result = {
        "resultText" => "OK"
    }

    begin

      image_file_name = params["imageFileName"]
      logging(image_file_name, "imageFileName")

      image_data       = image_data_in_params(params, "imageData")
      small_image_data = image_data_in_params(params, "smallImageData")

      if image_data.nil?
        logging("createSmallImage is here")
        image_file_base_name = File.basename(image_file_name)
        save_small_image(small_image_data, image_file_base_name, image_file_name)
        return result
      end

      save_dir             = $imageUploadDir
      image_file_base_name = new_file_name(image_file_name, "img")
      logging(image_file_base_name, "imageFileNameBase")

      upload_image_file_name = file_join(save_dir, image_file_base_name)
      logging(upload_image_file_name, "uploadImageFileName")

      open(upload_image_file_name, "wb+") do |file|
        file.write(image_data)
      end

      save_small_image(small_image_data, image_file_base_name, upload_image_file_name)
    rescue => e
      result["resultText"] = e.to_s
    end

    result
  end


  def image_data_in_params(params, key)
    value = params[key]

    check_result = check_filesize_on_mb(value, $UPLOAD_IMAGE_MAX_SIZE)
    raise check_result unless (check_result.empty?)

    value
  end


  def new_file_name(file_name, prefix = "")
    @new_file_name_index ||= 0

    ext_name = allowed_file_ext_name(file_name) || ''

    logging(ext_name, "extName")

    result = prefix + Time.now.to_f.to_s.gsub(/\./, '_') + "_" + @new_file_name_index.to_s + ext_name

    result.untaint
  end

  def delete_image
    logging("deleteImage begin")

    image_data = params
    logging(image_data, "imageData")

    url_list = image_data['imageUrlList']
    logging(url_list, "imageUrlList")

    image_files = all_image_file_name_from_tag_info_file
    add_local_image_to_list(image_files)
    logging(image_files, "imageFiles")

    url_file_name = $image_url_text
    logging(url_file_name, "imageUrlFileName")

    complete_count = 0
    result_text    = ""
    url_list.each do |imageUrl|
      if protected_image?(imageUrl)
        warning_message = "#{imageUrl}は削除できない画像です。"
        next
      end

      imageUrl.untaint
      result_delete_tags = delete_image_tags(imageUrl)
      result_delete_url  = delete_target_image_url(imageUrl, image_files, url_file_name)
      result             = (result_delete_tags or result_delete_url)

      if result
        complete_count += 1
      else
        warning_message = "不正な操作です。あなたが削除しようとしたファイル(#{imageUrl})はイメージファイルではありません。"
        loggingForce(warning_message)
        result_text += warning_message
      end
    end

    result_text += "#{complete_count}個のファイルを削除しました。"
    result      = { "resultText" => result_text }
    logging(result, "result")

    logging("deleteImage end")
    result
  end

  def protected_image?(image_url)
    $protectImagePaths.each do |url|
      if image_url.index(url) == 0
        return true
      end
    end

    false
  end

  def delete_target_image_url(image_url, image_files, image_url_file_name)
    logging(image_url, "deleteTargetImageUrl(imageUrl)")

    if image_files.include?(image_url) && File.exist?(image_url)
      delete_file(image_url)
      return true
    end

    locker = savefile_lock(image_url_file_name)
    locker.lock do
      lines = File.readlines(image_url_file_name)
      logging(lines, "lines")

      delete_result = lines.reject! { |i| i.chomp == image_url }

      unless delete_result
        return false
      end

      logging(lines, "lines deleted")
      create_file(image_url_file_name, lines.join)
    end

    true
  end

  #override
  def add_text_to_file(file_name, text)
    File.open(file_name, "a+") do |file|
      file.write(text)
    end
  end

  def upload_image_url
    logging("uploadImageUrl begin")

    image_data = params
    logging(image_data, "imageData")

    image_url = image_data['imageUrl']
    logging(image_url, "imageUrl")

    image_url_text = $image_url_text
    logging(image_url_text, "imageUrlFileName")

    result_text = "画像URLのアップロードに失敗しました。"
    locker      = savefile_lock(image_url_text)
    locker.lock do
      exists_urls = File.readlines(image_url_text).collect { |i| i.chomp }
      if exists_urls.include?(image_url)
        result_text = "すでに登録済みの画像URLです。"
      else
        add_text_to_file(image_url_text, (image_url + "\n"))
        result_text = "画像URLのアップロードに成功しました。"
      end
    end

    tag_info = image_data['tagInfo']
    logging(tag_info, 'uploadImageUrl.tagInfo')
    change_image_tags_local(image_url, tag_info)

    logging("uploadImageUrl end")

    { "resultText" => result_text }
  end


  def character_data_in_graveyard
    logging("getGraveyardCharacterData start.")
    result = []

    save_data(@savefiles['characters']) do |saveData|
      graveyard = saveData['graveyard']
      graveyard ||= []

      result = graveyard.reverse
    end

    result
  end

  def waiting_room_info
    logging("getWaitingRoomInfo start.")
    result = []

    save_data(@savefiles['characters']) do |saveData|
      waiting_room = waiting_room(saveData)
      result       = waiting_room
    end

    result
  end

  def set_waiting_room_info(data)
    change_save_data(@savefiles['characters']) do |saveData|
      waiting_room = waiting_room(saveData)
      waiting_room.concat(data)
    end
  end

  def image_list
    logging("getImageList start.")

    image_list = all_image_file_name_from_tag_info_file
    logging(image_list, "imageList all result")

    add_texts_character_image_list(image_list, $image_url_text)
    add_local_image_to_list(image_list)

    delete_invalid_image_filename(image_list)

    image_list.sort!

    image_list
  end

  def add_texts_character_image_list(image_list, *texts)
    texts.each do |text|
      next unless (File.exist?(text))

      lines = File.readlines(text)
      lines.each do |line|
        line.chomp!

        next if (line.empty?)
        next if (image_list.include?(line))

        image_list << line
      end
    end
  end

  def add_local_image_to_list(image_list)
    files = Dir.glob("#{$imageUploadDir}/*")

    files.each do |fileName|
      file = file.untaint #TODO:WHAT? このfileはどこから来たのか分からない

      next if (image_list.include?(fileName))
      next unless (allowed_file_ext?(fileName))

      image_list << fileName
      logging(fileName, "added local image")
    end
  end

  def delete_invalid_image_filename(image_list)
    image_list.delete_if { |i| (/\.txt$/===i) }
    image_list.delete_if { |i| (/\.lock$/===i) }
    image_list.delete_if { |i| (/\.json$/===i) }
    image_list.delete_if { |i| (/\.json~$/===i) }
    image_list.delete_if { |i| (/^.svn$/===i) }
    image_list.delete_if { |i| (/.db$/===i) }
  end


  def send_dicebot_chat_message
    logging 'sendDiceBotChatMessage'

    repeat_count = dicebot_repeat_count(params)

    message = params['message']

    results = []
    repeat_count.times do |i|
      message_once = message

      if repeat_count > 1
        message_once = message + " #" + (i + 1).to_s
      end

      logging(message_once, "sendDiceBotChatMessage oneMessage")
      result = send_dicebot_chat_message_once(params, message_once)
      logging(result, "sendDiceBotChatMessageOnece result")

      next if (result.nil?)
      results << result
    end

    logging(results, "sendDiceBotChatMessage results")

    results
  end

  def dicebot_repeat_count(params)
    repeat_count_limit = 20

    repeat_count = params['repeatCount']

    repeat_count ||= 1
    repeat_count = 1 if (repeat_count < 1)
    repeat_count = repeat_count_limit if (repeat_count > repeat_count_limit)

    repeat_count
  end

  def send_dicebot_chat_message_once(params, message)
    params_        = params.clone
    name           = params_['name']
    state          = params_['state']
    color          = params_['color']
    channel        = params_['channel']
    send_to        = params_['sendto']
    game_type      = params_['gameType']
    is_need_result = params_['isNeedResult']

    roll_result, is_secret, rand_results = dice_roll(message, game_type, is_need_result)

    logging(roll_result, 'rollResult')
    logging(is_secret, 'isSecret')
    logging(rand_results, "randResults")

    secret_result = ""
    if is_secret
      secret_result = message + roll_result
    else
      message = message + roll_result
    end

    message = chat_rolled_message(message, is_secret, rand_results, params)

    sender_name = name
    sender_name << ("\t" + state) unless (state.empty?)

    chat_data = {
        "senderName" => sender_name,
        "message"    => message,
        "color"      => color,
        "uniqueId"   => '0',
        "channel"    => channel
    }

    unless send_to.nil?
      chat_data['sendto'] = send_to
    end

    logging(chat_data, 'sendDiceBotChatMessage chatData')

    send_chat_message_by_chat_data(chat_data)


    result = nil
    if is_secret
      params_['isSecret'] = is_secret
      params_['message']  = secret_result
      result              = params_
    end

    result
  end

  def dice_roll(message, game_type, is_need_result)
    logging(message, 'rollDice message')
    logging(game_type, 'rollDice gameType')

    require 'cgiDiceBot.rb'
    bot                  = CgiDiceBot.new
    dir                  = dicebot_extra_table_dir_name
    result, rand_results = bot.roll(message, game_type, dir, @dicebot_table_prefix, is_need_result)

    result.gsub!(/＞/, '→')
    result.sub!(/\r?\n?\Z/, '')

    logging(result, 'rollDice result')

    return result, bot.isSecret, rand_results
  end

  def dicebot_extra_table_dir_name
    room_local_space_dir_name
  end


  def chat_rolled_message(message, is_secret, rand_results, params)
    logging("getChatRolledMessage Begin")
    logging(message, "message")
    logging(is_secret, "isSecret")
    logging(rand_results, "randResults")

    if is_secret
      message = "シークレットダイス"
    end

    rand_results = rand_results(rand_results, is_secret)

    if rand_results.nil?
      logging("randResults is nil")
      return message
    end


    data = {
        "chatMessage" => message,
        "randResults" => rand_results,
        "uniqueId"    => params['uniqueId'],
    }

    text = "###CutInCommand:rollVisualDice###" + DodontoFServer::build_json(data)
    logging(text, "getChatRolledMessage End text")

    text
  end

  def rand_results(rand_results, is_secret)
    logging(rand_results, 'getRandResults randResults')
    logging(is_secret, 'getRandResults isSecret')

    if is_secret
      rand_results = rand_results.collect { |value, max| [0, 0] }
    end

    logging(rand_results, 'getRandResults result')

    rand_results
  end


  def send_chat_message_all
    logging("sendChatMessageAll Begin")

    result = { 'result' => "NG" }

    return result if ($mentenanceModePassword.nil?)
    chat_data = params

    password = chat_data["password"]
    logging(password, "password check...")
    return result unless (password == $mentenanceModePassword)

    logging("adminPoassword check OK.")

    rooms = []

    $saveDataMaxCount.times do |roomNumber|
      logging(roomNumber, "loop roomNumber")

      init_savefiles(roomNumber)

      true_savefile_name = @savedir_info.real_savefile_name($play_room_info_file_name)
      next unless (File.exist?(true_savefile_name))

      logging(roomNumber, "sendChatMessageAll to No.")
      send_chat_message_by_chat_data(chat_data)

      rooms << roomNumber
    end

    result['result'] = "OK"
    result['rooms']  = rooms
    logging(result, "sendChatMessageAll End, result")

    result
  end

  def send_chat_message
    chat_data = params
    send_chat_message_by_chat_data(chat_data)

    return nil
  end

  def send_chat_message_by_chat_data(chat_data)

    chat_message_data = nil

    change_save_data(@savefiles['chatMessageDataLog']) do |saveData|
      chat_message_data_log = chat_message_data_log(saveData)

      delete_old_chat_message_data(chat_message_data_log)

      now               = Time.now.to_f
      chat_message_data = [now, chat_data]

      chat_message_data_log.push(chat_message_data)
      chat_message_data_log.sort!

      logging(chat_message_data_log, "chatMessageDataLog")
      logging(saveData['chatMessageDataLog'], "saveData['chatMessageDataLog']")
    end

    if $IS_SAVE_LONG_CHAT_LOG
      save_all_chat_message(chat_message_data)
    end
  end

  def delete_old_chat_message_data(chat_message_data_log)
    now = Time.now.to_f

    chat_message_data_log.delete_if do |chatMessageData|
      written_time, chat_message, *dummy = chatMessageData
      time_diff                          = now - written_time

      (time_diff > ($oldMessageTimeout))
    end
  end


  def delete_chat_log
    true_savefile_name = @savefiles['chatMessageDataLog']
    delete_chat_log_by_savefile(true_savefile_name)

    { 'result' => "OK" }
  end

  def delete_chat_log_by_savefile(true_savefile_name)
    change_save_data(true_savefile_name) do |saveData|
      chat_message_data_log = chat_message_data_log(saveData)
      chat_message_data_log.clear
    end

    delete_chat_log_all
  end

  def delete_chat_log_all
    logging("deleteChatLogAll Begin")

    file = @savedir_info.real_savefile_name($chat_long_line_file_name)
    logging(file, "file")

    if File.exist?(file)
      locker = savefile_lock(file)
      locker.lock do
        File.delete(file)
      end
    end

    logging("deleteChatLogAll End")
  end


  def chat_message_data_log(save_data)
    array_info(save_data, 'chatMessageDataLog')
  end


  def save_all_chat_message(chat_message_data)
    logging(chat_message_data, 'saveAllChatMessage chatMessageData')

    if chat_message_data.nil?
      return
    end

    savefile_name = @savedir_info.real_savefile_name($chat_long_line_file_name)

    locker = savefile_lock(savefile_name)
    locker.lock do

      lines = []
      if File.exist?(savefile_name)
        lines = File.readlines(savefile_name)
      end
      lines << DodontoFServer::build_json(chat_message_data)
      lines << "\n"

      while lines.size > $chatMessageDataLogAllLineMax
        lines.shift
      end

      create_file(savefile_name, lines.join)
    end

  end

  def change_map
    map_data = params
    logging(map_data, "mapData")

    change_map_savedata(map_data)

    return nil
  end

  def change_map_savedata(map_data)
    logging("changeMap start.")

    change_save_data(@savefiles['map']) do |saveData|
      draws = draws(saveData)
      set_map_data(saveData, map_data)
      draws.each { |i| set_draws(saveData, i) }
    end
  end


  def set_map_data(save_data, map_data)
    save_data['mapData'] ||= {}
    save_data['mapData'] = map_data
  end

  def map_data(save_data)
    save_data['mapData'] ||= {}
    save_data['mapData']
  end


  def draw_on_map
    logging('drawOnMap Begin')

    data = params['data']
    logging(data, 'data')

    change_save_data(@savefiles['map']) do |saveData|
      set_draws(saveData, data)
    end

    logging('drawOnMap End')

    return nil
  end

  def set_draws(save_data, data)
    return if (data.nil?)
    return if (data.empty?)

    info = data.first
    if info['imgId'].nil?
      info['imgId'] = create_character_img_id('draw_')
    end

    draws = draws(save_data)
    draws << data
  end

  def draws(save_data)
    map_data          = map_data(save_data)
    map_data['draws'] ||= []
    map_data['draws']
  end

  def clear_draw_on_map
    change_save_data(@savefiles['map']) do |saveData|
      draws = draws(saveData)
      draws.clear
    end

    return nil
  end

  def undo_draw_on_map
    result = {
        'data' => nil
    }

    change_save_data(@savefiles['map']) do |saveData|
      draws          = draws(saveData)
      result['data'] = draws.pop
    end

    result
  end


  def add_effect
    effect_data      = params
    effect_data_list = [effect_data]
    add_effect_data(effect_data_list)

    return nil
  end

  def find_effect(effects, keys, data)
    found = nil

    effects.find do |effect|
      all_matched = true

      keys.each do |key|
        if effect[key] != data[key]
          all_matched = false
          break
        end
      end

      if all_matched
        found = effect
        break
      end
    end

    found
  end

  def add_effect_data(effect_data_list)
    change_save_data(@savefiles['effects']) do |saveData|
      saveData['effects'] ||= []
      effects             = saveData['effects']

      effect_data_list.each do |effectData|
        logging(effectData, "addEffectData target effectData")

        if effectData['type'] == 'standingGraphicInfos'
          keys  = ['type', 'name', 'state']
          found = find_effect(effects, keys, effectData)

          if found
            logging(found, "addEffectData is already exist, found data is => ")
            next
          end
        end

        effectData['effectId'] = create_character_img_id("effects_")
        effects << effectData
      end
    end
  end

  def change_effect
    change_save_data(@savefiles['effects']) do |saveData|
      effect_data     = params
      target_cutin_id = effect_data['effectId']

      saveData['effects'] ||= []
      effects             = saveData['effects']

      find_index = -1
      effects.each_with_index do |i, index|
        if target_cutin_id == i['effectId']
          find_index = index
        end
      end

      if find_index == -1
        return
      end

      effects[find_index] = effect_data
    end

    return nil
  end

  def remove_effect
    logging('removeEffect Begin')

    change_save_data(@savefiles['effects']) do |saveData|

      effect_id = params['effectId']
      logging(effect_id, 'effectId')

      saveData['effects'] ||= []
      effects             = saveData['effects']
      effects.delete_if { |i| (effect_id == i['effectId']) }
    end

    logging('removeEffect End')

    return nil
  end


  def image_info_file_name
    image_info_file_name = file_join($imageUploadDir, 'imageInfo.json')

    logging(image_info_file_name, 'imageInfoFileName')

    image_info_file_name
  end

  def change_image_tags
    effect_data = params
    source      = effect_data['source']
    tag_info    = effect_data['tagInfo']

    change_image_tags_local(source, tag_info)

    return nil
  end

  def all_image_file_name_from_tag_info_file
    image_file_names = []

    save_data(image_info_file_name) do |saveData|
      image_tags       = saveData['imageTags']
      image_tags       ||= {}
      image_file_names = image_tags.keys
    end

    image_file_names
  end

  def change_image_tags_local(source, tag_info)
    return if (tag_info.nil?)

    change_save_data(image_info_file_name) do |saveData|
      saveData['imageTags'] ||= {}
      image_tags            = saveData['imageTags']

      image_tags[source] = tag_info
    end
  end

  def delete_image_tags(source)

    change_save_data(image_info_file_name) do |saveData|

      image_tags = saveData['imageTags']

      tag_info = image_tags.delete(source)
      return false if (tag_info.nil?)

      small_image = tag_info["smallImage"]
      begin
        delete_file(small_image)
      rescue => e
        error_message = error_response_body(e)
        logging_exception(e)
      end
    end

    true
  end

  def delete_file(file)
    File.delete(file)
  end

  def image_tags_and_image_list
    result = {}

    result['tagInfos']  = image_tags
    result['imageList'] = image_list
    result['imageDir']  = $imageUploadDir

    logging("getImageTagsAndImageList result", result)

    result
  end

  def image_tags
    logging('getImageTags start')
    image_tags = nil

    save_data(image_info_file_name) do |saveData|
      image_tags = saveData['imageTags']
    end

    image_tags ||= {}
    logging(image_tags, 'getImageTags imageTags')

    image_tags
  end

  def create_character_img_id(prefix = "character_")
    @imgIdIndex ||= 0
    @imgIdIndex += 1

    #return (prefix + Time.now.to_f.to_s + "_" + @imgIdIndex.to_s);
    (prefix + sprintf("%.4f_%04d", Time.now.to_f, @imgIdIndex))
  end


  def add_character
    character_data      = params
    character_data_list = [character_data]

    add_character_data(character_data_list)
  end


  def already_exist_character?(characters, character_data)
    return false if (character_data['name'].nil?)
    return false if (character_data['name'].empty?)

    already_exist = characters.find do |i|
      (i['imgId'] == character_data['imgId']) or
          (i['name'] == character_data['name'])
    end

    return false if (already_exist.nil?)

    logging("target characterData is already exist. no creation.", "isAlreadyExistCharacter?")
    character_data['name']
  end

  def add_character_data(character_data_list)
    result = {
        "addFailedCharacterNames" => []
    }

    change_save_data(@savefiles['characters']) do |saveData|
      saveData['characters'] ||= []
      characters             = characters(saveData)

      character_data_list.each do |characterData|
        logging(characterData, "characterData")

        characterData['imgId'] = create_character_img_id

        failed_name = already_exist_character_in_room?(saveData, characterData)

        if failed_name
          result["addFailedCharacterNames"] << failed_name
          next
        end

        logging("add characterData to characters")
        characters << characterData
      end
    end

    result
  end

  def already_exist_character_in_room?(save_data, character_data)
    characters     = characters(save_data)
    waiting_room   = waiting_room(save_data)
    all_characters = (characters + waiting_room)

    failed_name = already_exist_character?(all_characters, character_data)
  end


  def change_character
    character_data = params
    logging(character_data.inspect, "characterData")

    change_character_data(character_data)

    return nil
  end

  def change_character_data(character_data)
    change_save_data(@savefiles['characters']) do |saveData|
      logging("changeCharacterData called")

      characters = characters(saveData)

      index = nil
      characters.each_with_index do |item, targetIndex|
        if item['imgId'] == character_data['imgId']
          index = targetIndex
          break
        end
      end

      if index.nil?
        logging("invalid character name")
        return
      end

      unless character_data['name'].nil? or character_data['name'].empty?
        already_exist = characters.find do |character|
          ((character['name'] == character_data['name']) and
              (character['imgId'] != character_data['imgId']))
        end

        if already_exist
          logging("same name character alread exist")
          return
        end
      end

      logging(character_data.inspect, "character data change")
      characters[index] = character_data
    end
  end

  def card_type
    "Card"
  end

  def card_mount_type
    "CardMount"
  end

  def random_dungeon_card_mount_type
    "RandomDungeonCardMount"
  end

  def card_trash_mount_type
    "CardTrushMount"
  end

  def random_dungeon_card_trash_mount_type
    "RandomDungeonCardTrushMount"
  end

  def rotation(is_up_down)
    rotation = 0

    if is_up_down && rand(2) == 0
      rotation = 180
    end

    rotation
  end

  def card_data(is_text, image_name, image_name_back, mount_name, is_up_down = false, can_delete = false)

    card_data = {
        "imageName"     => image_name,
        "imageNameBack" => image_name_back,
        "isBack"        => true,
        "rotation"      => rotation(is_up_down),
        "isUpDown"      => is_up_down,
        "isText"        => is_text,
        "isOpen"        => false,
        "owner"         => "",
        "ownerName"     => "",
        "mountName"     => mount_name,
        "canDelete"     => can_delete,

        "name"          => "",
        "imgId"         => create_character_img_id,
        "type"          => card_type,
        "x"             => 0,
        "y"             => 0,
        "draggable"     => true,
    }

  end


  def add_card_zone
    logging("addCardZone Begin")

    data = params

    x          = data['x']
    y          = data['y']
    owner      = data['owner']
    owner_name = data['ownerName']

    change_save_data(@savefiles['characters']) do |saveData|
      characters = characters(saveData)
      logging(characters, "addCardZone characters")

      card_data = card_zone_data(owner, owner_name, x, y)
      characters << card_data
    end

    logging("addCardZone End")
    return nil
  end


  def init_cards
    logging("initCards Begin")

    set_record_empty

    clear_character_by_type_local(card_type)
    clear_character_by_type_local(card_mount_type)
    clear_character_by_type_local(random_dungeon_card_mount_type)
    clear_character_by_type_local(card_zone_type)
    clear_character_by_type_local(card_trash_mount_type)
    clear_character_by_type_local(random_dungeon_card_trash_mount_type)

    card_type_infos = params['cardTypeInfos']
    logging(card_type_infos, "cardTypeInfos")

    change_save_data(@savefiles['characters']) do |saveData|
      saveData['cardTrushMount'] = {}

      saveData['cardMount'] = {}
      card_mounts           = saveData['cardMount']

      characters = characters(saveData)
      logging(characters, "initCards saveData.characters")

      card_type_infos.each_with_index do |cardTypeInfo, index|
        mount_name = cardTypeInfo['mountName']
        logging(mount_name, "initCards mountName")

        cards_list_file_name = cards_info.getCardFileName(mount_name)
        logging(cards_list_file_name, "initCards cardsListFileName")

        cards_list = []
        File.readlines(cards_list_file_name).each_with_index do |i, lineIndex|
          cards_list << i.chomp.toutf8
        end

        logging(cards_list, "initCards cardsList")

        card_data  = cards_list.shift.split(/,/)
        is_text    = (card_data.shift == "text")
        is_up_down = (card_data.shift == "upDown")
        logging("isUpDown", is_up_down)
        image_name_back = cards_list.shift

        cards_list, is_sorted   = initialize_card_set(cards_list, cardTypeInfo)
        card_mounts[mount_name] = initialized_card_mount(cards_list, mount_name, is_text, is_up_down, image_name_back, is_sorted)

        card_mount_data = createCardMountData(card_mounts, is_text, image_name_back, mount_name, index, is_up_down, cardTypeInfo, cards_list)
        characters << card_mount_data

        card_trash_mount_data = card_trash_mount_data(is_text, mount_name, index, cardTypeInfo)
        characters << card_trash_mount_data
      end

      wait_for_refresh = 0.2
      sleep(wait_for_refresh)
    end

    logging("initCards End")

    card_exist = (not card_type_infos.empty?)
    { "result" => "OK", "cardExist" => card_exist }
  end


  def initialized_card_mount(cards_list, mount_name, is_text, is_up_down, image_name_back, is_sorted)
    card_mount = []

    cards_list.each do |imageName|
      if /^###Back###(.+)/ === imageName
        image_name_back = $1
        next
      end

      logging(imageName, "initCards imageName")
      card_data = card_data(is_text, imageName, image_name_back, mount_name, is_up_down)
      card_mount << card_data
    end

    if is_sorted
      card_mount = card_mount.reverse
    else
      card_mount = card_mount.sort_by { rand }
    end

    card_mount
  end


  def add_card
    logging("addCard begin")

    add_card_data = params

    is_text         = add_card_data['isText']
    image_name      = add_card_data['imageName']
    image_name_back = add_card_data['imageNameBack']
    mount_name      = add_card_data['mountName']
    is_up_down      = add_card_data['isUpDown']
    can_delete      = add_card_data['canDelete']
    is_open         = add_card_data['isOpen']
    is_back         = add_card_data['isBack']

    change_save_data(@savefiles['characters']) do |saveData|
      card_data      = card_data(is_text, image_name, image_name_back, mount_name, is_up_down, can_delete)
      card_data["x"] = add_card_data['x']
      card_data["y"] = add_card_data['y']
      card_data["isOpen"] = is_open unless (is_open.nil?)
      card_data["isBack"] = is_back unless (is_back.nil?)

      characters = characters(saveData)
      characters << card_data
    end

    logging("addCard end")

    return nil
  end

  #トランプのジョーカー枚数、使用デッキ数の指定
  def initialize_card_set(cards_list, card_type_info)
    if random_dungeon_trump?(card_type_info)
      cards_list_tmp = init_card_set_for_random_dungen_trump(cards_list, card_type_info)
      return cards_list_tmp, true
    end

    use_line_count = card_type_info['useLineCount']
    use_line_count ||= cards_list.size
    logging(use_line_count, 'useLineCount')

    deck_count = card_type_info['deckCount']
    deck_count ||= 1
    logging(deck_count, 'deckCount')

    cards_list_tmp = []
    deck_count.to_i.times do
      cards_list_tmp += cards_list[0...use_line_count]
    end

    return cards_list_tmp, false
  end

  def init_card_set_for_random_dungen_trump(card_list, card_type_info)
    logging("getInitCardSetForRandomDungenTrump start")

    logging(card_list.length, "cardList.length")
    logging(card_type_info, "cardTypeInfo")

    use_count    = card_type_info['cardCount']
    jorker_count = card_type_info['jorkerCount']

    use_line_count = 13 * 4 + jorker_count
    card_list      = card_list[0...use_line_count]
    logging(card_list.length, "cardList.length")

    ace_list    = []
    no_ace_list = []

    card_list.each_with_index do |card, index|
      if (index % 13) == 0 && ace_list.length < 4
        ace_list << card
        next
      end

      no_ace_list << card
    end

    logging(ace_list, "aceList")
    logging(ace_list.length, "aceList.length")
    logging(no_ace_list.length, "noAceList.length")

    card_type_info['aceList'] = ace_list.clone

    result = []

    ace_list = ace_list.sort_by { rand }
    result << ace_list.shift
    logging(ace_list, "aceList shifted")
    logging(result, "result")

    no_ace_list = no_ace_list.sort_by { rand }

    while result.length < use_count
      result << no_ace_list.shift
      break if (no_ace_list.length <= 0)
    end

    result = result.sort_by { rand }
    logging(result, "result.sorted")
    logging(no_ace_list, "noAceList is empty? please check")

    while ace_list.length > 0
      result << ace_list.shift
    end

    while no_ace_list.length > 0
      result << no_ace_list.shift
    end

    logging(result, "getInitCardSetForRandomDungenTrump end, result")

    result
  end


  def card_zone_type
    "CardZone"
  end

  def card_zone_data(owner, owner_name, x, y)
    # cardMount, isText, imageNameBack, mountName, index, isUpDown)
    is_text         = true
    card_text       = ""
    card_mount_data = card_data(is_text, card_text, card_text, "noneMountName")

    card_mount_data['type']      = card_zone_type
    card_mount_data['owner']     = owner
    card_mount_data['ownerName'] = owner_name
    card_mount_data['x']         = x
    card_mount_data['y']         = y

    card_mount_data
  end


  def createCardMountData(card_mount, is_text, image_name_back, mount_name, index, is_up_down, card_type_info, cards)
    card_mount_data = card_data(is_text, image_name_back, image_name_back, mount_name)

    card_mount_data['type'] = card_mount_type
    set_card_count_and_back_image(card_mount_data, card_mount[mount_name])
    card_mount_data['mountName'] = mount_name
    card_mount_data['isUpDown']  = is_up_down
    card_mount_data['x']         = init_card_mount_x(index)
    card_mount_data['y']         = init_card_mount_y(0)

    unless cards.first.nil?
      card_mount_data['nextCardId'] = cards.first['imgId']
    end

    if random_dungeon_trump?(card_type_info)
      card_count                              = card_type_info['cardCount']
      card_mount_data['type']                 = random_dungeon_card_mount_type
      card_mount_data['cardCountDisplayDiff'] = cards.length - card_count
      card_mount_data['useCount']             = card_count
      card_mount_data['aceList']              = card_type_info['aceList']
    end

    card_mount_data
  end

  def init_card_mount_x(index)
    50 + index * 150
  end

  def init_card_mount_y(index)
    50 + index * 200
  end

  def random_dungeon_trump?(card_type_info)
    card_type_info['mountName'] == 'randomDungeonTrump'
  end

  def card_trash_mount_data(is_text, mount_name, index, card_type_info)
    image_name, image_name_back, is_text = card_trash_mount_image_name(mount_name)
    card_trash_mount_data                = card_data(is_text, image_name, image_name_back, mount_name)

    card_trash_mount_data['type']      = card_trash_mount_type_from_card_type_info(card_type_info)
    card_trash_mount_data['cardCount'] = 0
    card_trash_mount_data['mountName'] = mount_name
    card_trash_mount_data['x']         = init_card_mount_x(index)
    card_trash_mount_data['y']         = init_card_mount_y(1)
    card_trash_mount_data['isBack']    = false

    card_trash_mount_data
  end

  def set_trash_mount_data_cards_info(save_data, card_mount_data, cards)
    characters = characters(save_data)
    mount_name = card_mount_data['mountName']

    image_name, image_name_back, is_text = card_trash_mount_image_name(mount_name, cards)

    card_mount_image_data = find_card_mount_data_by_type(characters, mount_name, card_trash_mount_type)
    return if (card_mount_image_data.nil?)

    card_mount_image_data['cardCount']     = cards.size
    card_mount_image_data["imageName"]     = image_name
    card_mount_image_data["imageNameBack"] = image_name
    card_mount_image_data["isText"]        = is_text
  end

  def card_trash_mount_image_name(mount_name, cards = [])
    card_data = cards.last

    image_name      = ""
    image_name_back = ""
    is_text         = true

    if card_data.nil?
      card_title = cards_info.getCardTitleName(mount_name)

      is_text         = true
      image_name      = "<font size=\"40\">#{card_title}用<br>カード捨て場</font>"
      image_name_back = image_name
    else
      is_text         = card_data["isText"]
      image_name      = card_data["imageName"]
      image_name_back = card_data["imageNameBack"]

      if card_data["owner"] == "nobody"
        image_name = image_name_back
      end
    end

    return image_name, image_name_back, is_text
  end

  def card_trash_mount_type_from_card_type_info(card_type_info)
    if random_dungeon_trump?(card_type_info)
      return random_dungeon_card_trash_mount_type
    end

    card_trash_mount_type
  end


  def return_card
    logging("returnCard Begin")

    set_no_body_sender

    mount_name = params['mountName']
    logging(mount_name, "mountName")

    change_save_data(@savefiles['characters']) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      card_data = trash_cards.pop
      logging(card_data, "cardData")
      if card_data.nil?
        logging("returnCard trushCards is empty. END.")
        return
      end

      card_data['x'] = params['x'] + 150
      card_data['y'] = params['y'] + 10
      logging('returned cardData', card_data)

      characters = characters(saveData)
      characters.push(card_data)

      trash_mount_data = find_card_data(characters, params['imgId'])
      logging(trash_mount_data, "returnCard trushMountData")

      return if (trash_mount_data.nil?)

      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)
    end

    logging("returnCard End")

    return nil
  end

  def draw_card
    logging("drawCard Begin")

    set_no_body_sender

    logging(params, 'params')

    result = {
        "result" => "NG"
    }

    change_save_data(@savefiles['characters']) do |saveData|
      count = params['count']

      count.times do
        draw_card_data_one(params, saveData)
      end

      result["result"] = "OK"
    end

    logging("drawCard End")

    result
  end

  def draw_card_data_one(params, save_data)
    card_mount = card_mount(save_data)

    mount_name = params['mountName']
    cards      = cards(card_mount, mount_name)

    card_mount_data = find_card_mount_data(save_data, params['imgId'])
    return if (card_mount_data.nil?)

    card_count_display_diff = card_mount_data['cardCountDisplayDiff']
    unless card_count_display_diff.nil?
      return if (card_count_display_diff >= cards.length)
    end

    card_data = cards.pop
    return if (card_data.nil?)

    card_data['x'] = params['x']
    card_data['y'] = params['y']

    is_open                = params['isOpen']
    card_data['isOpen']    = is_open
    card_data['isBack']    = false
    card_data['owner']     = params['owner']
    card_data['ownerName'] = params['ownerName']

    characters = characters(save_data)
    characters << card_data

    logging(cards.size, 'cardMount[mountName].size')
    set_card_count_and_back_image(card_mount_data, cards)
  end


  def draw_target_trash_card
    logging("drawTargetTrushCard Begin")

    set_no_body_sender

    mount_name = params['mountName']
    logging(mount_name, "mountName")

    change_save_data(@savefiles['characters']) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      card_data = remove_from_array(trash_cards) { |i| i['imgId'] === params['targetCardId'] }
      logging(card_data, "cardData")
      return if (card_data.nil?)

      card_data['x'] = params['x']
      card_data['y'] = params['y']

      characters = characters(saveData)
      characters.push(card_data)

      trash_mount_data = find_card_data(characters, params['mountId'])
      logging(trash_mount_data, "returnCard trushMountData")

      return if (trash_mount_data.nil?)

      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)
    end

    logging("drawTargetTrushCard End")

    { "result" => "OK" }
  end

  def draw_target_card
    logging("drawTargetCard Begin")

    set_no_body_sender

    logging(params, 'params')

    mount_name = params['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savefiles['characters']) do |saveData|
      card_mount = card_mount(saveData)
      cards      = cards(card_mount, mount_name)
      card_data  = cards.find { |i| i['imgId'] === params['targetCardId'] }

      if card_data.nil?
        logging(params['targetCardId'], "not found params['targetCardId']")
        return
      end

      cards.delete(card_data)

      card_data['x'] = params['x']
      card_data['y'] = params['y']

      card_data['isOpen']    = false
      card_data['isBack']    = false
      card_data['owner']     = params['owner']
      card_data['ownerName'] = params['ownerName']

      saveData['characters'] ||= []
      characters             = characters(saveData)
      characters << card_data

      card_mount_data = find_card_mount_data(saveData, params['mountId'])
      if card_mount_data.nil?
        logging(params['mountId'], "not found params['mountId']")
        return
      end

      logging(cards.size, 'cardMount[mountName].size')
      set_card_count_and_back_image(card_mount_data, cards)
    end

    logging("drawTargetCard End")

    { "result" => "OK" }
  end

  def find_card_mount_data(save_data, mount_id)
    characters = characters(save_data)
    characters.find { |i| i['imgId'] === mount_id }
  end


  def set_card_count_and_back_image(card_mount_data, cards)
    card_mount_data['cardCount'] = cards.size

    card = cards.last
    return if (card.nil?)

    image = card["imageNameBack"]
    return if (image.nil?)

    card_mount_data["imageNameBack"] = image
  end

  def dump_trash_cards
    logging("dumpTrushCards Begin")

    set_no_body_sender

    dump_trash_cards = params
    logging(dump_trash_cards, 'dumpTrushCardsData')

    mount_name = dump_trash_cards['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savefiles['characters']) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      characters = characters(saveData)

      dumped_card_id = dump_trash_cards['dumpedCardId']
      logging(dumped_card_id, "dumpedCardId")

      logging(characters.size, "characters.size before")
      card_data = delete_find_one(characters) { |i| i['imgId'] === dumped_card_id }
      trash_cards << card_data
      logging(characters.size, "characters.size after")

      trash_mount_data = characters.find { |i| i['imgId'] === dump_trash_cards['trushMountId'] }
      if trash_mount_data.nil?
        return
      end

      logging(trash_mount, 'trushMount')
      logging(mount_name, 'mountName')
      logging(trash_mount[mount_name], 'trushMount[mountName]')
      logging(trash_mount[mount_name].size, 'trushMount[mountName].size')

      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)
    end

    logging("dumpTrushCards End")
    return nil
  end

  def delete_find_one(array)
    find_index = nil
    array.each_with_index do |i, index|
      if yield(i)
        find_index = index
      end
    end

    if find_index.nil?
      throw Exception.new("deleteFindOne target is NOT found inspect:") #+ array.inspect)
    end

    logging(array.size, "array.size before")
    item = array.delete_at(find_index)
    logging(array.size, "array.size before")

    item
  end

  def shuffle_cards
    logging("shuffleCard Begin")

    set_record_empty

    mount_name     = params['mountName']
    trash_mount_id = params['mountId']
    is_shuffle     = params['isShuffle']

    logging(mount_name, 'mountName')
    logging(trash_mount_id, 'trushMountId')

    change_save_data(@savefiles['characters']) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      card_mount  = card_mount(saveData)
      mount_cards = cards(card_mount, mount_name)

      while trash_cards.size > 0
        card_data = trash_cards.pop
        init_trash_card_for_return_mount(card_data)
        mount_cards << card_data
      end

      characters = characters(saveData)

      trash_mount_data = find_card_data(characters, trash_mount_id)
      return if (trash_mount_data.nil?)
      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)

      card_mount_data = find_card_mount_data_by_type(characters, mount_name, card_mount_type)
      return if (card_mount_data.nil?)

      if is_shuffle
        is_up_down  = card_mount_data['isUpDown']
        mount_cards = shuffle_mount(mount_cards, is_up_down)
      end

      card_mount[mount_name] = mount_cards
      saveData['cardMount']  = card_mount

      set_card_count_and_back_image(card_mount_data, mount_cards)
    end

    logging("shuffleCard End")
    return nil
  end


  def shuffle_next_random_dungeon
    logging("shuffleForNextRandomDungeon Begin")

    set_record_empty

    mount_name     = params['mountName']
    trash_mount_id = params['mountId']

    logging(mount_name, 'mountName')
    logging(trash_mount_id, 'trushMountId')

    change_save_data(@savefiles['characters']) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)
      logging(trash_cards.length, "trushCards.length")

      saveData['cardMount']  ||= {}
      card_mount             = saveData['cardMount']
      card_mount[mount_name] ||= []
      mount_cards            = card_mount[mount_name]

      characters      = characters(saveData)
      card_mount_data = find_card_mount_data_by_type(characters, mount_name, random_dungeon_card_mount_type)
      return if (card_mount_data.nil?)

      ace_list = card_mount_data['aceList']
      logging(ace_list, "aceList")

      ace_cards = []
      ace_cards += delete_ace_from_cards(trash_cards, ace_list)
      ace_cards += delete_ace_from_cards(mount_cards, ace_list)
      ace_cards += delete_ace_from_cards(characters, ace_list)
      ace_cards = ace_cards.sort_by { rand }

      logging(ace_cards, "aceCards")
      logging(trash_cards.length, "trushCards.length")
      logging(mount_cards.length, "mountCards.length")

      use_count = card_mount_data['useCount']
      if (mount_cards.size + 1) < use_count
        use_count = (mount_cards.size + 1)
      end

      mount_cards = mount_cards.sort_by { rand }

      insert_point = rand(use_count)
      logging(insert_point, "insertPoint")
      mount_cards[insert_point, 0] = ace_cards.shift

      while ace_cards.length > 0
        mount_cards[use_count, 0] = ace_cards.shift
        logging(use_count, "useCount")
      end

      mount_cards = mount_cards.reverse

      card_mount[mount_name] = mount_cards
      saveData['cardMount']  = card_mount

      new_diff = mount_cards.size - use_count
      new_diff = 3 if (new_diff < 3)
      logging(new_diff, "newDiff")
      card_mount_data['cardCountDisplayDiff'] = new_diff


      trash_mount_data = find_card_data(characters, trash_mount_id)
      return if (trash_mount_data.nil?)
      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)

      set_card_count_and_back_image(card_mount_data, mount_cards)
    end

    logging("shuffleForNextRandomDungeon End")

    return nil
  end

  def delete_ace_from_cards(cards, ace_list)
    result = cards.select { |i| ace_list.include?(i['imageName']) }
    cards.delete_if { |i| ace_list.include?(i['imageName']) }

    result
  end

  def find_card_data(characters, card_id)
    characters.find { |i| i['imgId'] === card_id }
  end

  def find_card_mount_data_by_type(characters, mount_name, card_mount_type)
    card_mount_data = characters.find do |i|
      ((i['type'] === card_mount_type) && (i['mountName'] == mount_name))
    end
  end

  def shuffle_mount(mount_cards, is_up_down)
    mount_cards = mount_cards.sort_by { rand }
    mount_cards.each do |i|
      i["rotation"] = rotation(is_up_down)
    end

    mount_cards
  end

  def init_trash_card_for_return_mount(card_data)
    card_data['isOpen']    = false
    card_data['isBack']    = true
    card_data['owner']     = ""
    card_data['ownerName'] = ""
  end


  def find_trash_mount_and_cards(save_data, mount_name)
    save_data['cardTrushMount'] ||= {}
    trash_mount                 = save_data['cardTrushMount']

    trash_mount[mount_name] ||= []
    trash_cards             = trash_mount[mount_name]

    return trash_mount, trash_cards
  end

  def mount_card_infos
    logging(params, 'getTrushMountCardInfos params')

    mount_name = params['mountName']
    mount_id   = params['mountId']

    cards = []

    change_save_data(@savefiles['characters']) do |saveData|
      card_mount = card_mount(saveData)
      cards      = cards(card_mount, mount_name)

      card_mount_data         = find_card_mount_data(saveData, mount_id)
      card_count_display_diff = card_mount_data['cardCountDisplayDiff']

      logging(card_count_display_diff, "cardCountDisplayDiff")
      logging(cards.length, "before cards.length")

      unless card_count_display_diff.nil?
        unless cards.empty?
          cards = cards[card_count_display_diff .. -1]
        end
      end

    end

    logging(cards.length, "getMountCardInfos cards.length")

    cards
  end

  def trash_mount_card_infos

    logging(params, 'getTrushMountCardInfos params')

    mount_name = params['mountName']
    mount_id   = params['mountId']

    cards = []

    change_save_data(@savefiles['characters']) do |saveData|
      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)
      cards                    = trash_cards
    end

    cards
  end


  def clear_character_by_type
    logging "clearCharacterByType Begin"

    set_record_empty

    clear_data = params
    logging(clear_data, 'clearData')

    target_types = clear_data['types']
    logging(target_types, 'targetTypes')

    target_types.each do |targetType|
      clear_character_by_type_local(targetType)
    end

    logging "clearCharacterByType End"

    return nil
  end

  def clear_character_by_type_local(target_type)
    logging(target_type, "clearCharacterByTypeLocal targetType")

    change_save_data(@savefiles['characters']) do |saveData|
      characters = characters(saveData)

      characters.delete_if do |i|
        (i['type'] == target_type)
      end
    end

    logging("clearCharacterByTypeLocal End")
  end


  def remove_character
    remove_character_list = params
    remove_character_by_remove_character_data_list(remove_character_list)

    return nil
  end


  def remove_character_by_remove_character_data_list(remove_character_list) #TODO:FIXME 正直、どういうことを意図しているメソッドなのか分からない。。。
    logging(remove_character_list, "removeCharacterDataList")

    change_save_data(@savefiles['characters']) do |saveData|
      characters = characters(saveData)

      remove_character_list.each do |removeCharacterData|
        logging(removeCharacterData, "removeCharacterData")

        remove_character_id = removeCharacterData['imgId']
        logging(remove_character_id, "removeCharacterId")
        is_goto_graveyard = removeCharacterData['isGotoGraveyard']
        logging(is_goto_graveyard, "isGotoGraveyard")

        characters.delete_if do |i|
          deleted = (i['imgId'] == remove_character_id)

          if deleted and is_goto_graveyard
            bury_character(i, saveData)
          end

          deleted
        end
      end

      logging(characters, "character deleted result")
    end
  end

  def bury_character(character, save_data)
    save_data['graveyard'] ||= []
    graveyard              = save_data['graveyard']

    graveyard << character

    while graveyard.size > $graveyardLimit
      graveyard.shift
    end
  end


  def enter_waiting_room_character

    set_record_empty

    character_id = params['characterId']

    logging(character_id, "enterWaitingRoomCharacter characterId")

    result = { "result" => "NG" }
    change_save_data(@savefiles['characters']) do |saveData|
      characters = characters(saveData)

      enter_character_data = remove_from_array(characters) { |i| (i['imgId'] == character_id) }
      return result if (enter_character_data.nil?)

      waiting_room = waiting_room(saveData)
      waiting_room << enter_character_data
    end

    result["result"] = "OK"
    result
  end


  def resurrect_character
    img_id = params['imgId']
    logging(img_id, "resurrectCharacterId")

    change_save_data(@savefiles['characters']) do |saveData|
      _graveyard = graveyard(saveData)

      character_data = remove_from_array(_graveyard) do |character|
        character['imgId'] == img_id
      end

      logging(character_data, "resurrectCharacter CharacterData")
      return if (character_data.nil?)

      characters = characters(saveData)
      characters << character_data
    end

    nil
  end

  def clear_graveyard
    logging("clearGraveyard begin")

    change_save_data(@savefiles['characters']) do |saveData|
      graveyard = graveyard(saveData)
      graveyard.clear
    end

    nil
  end


  def graveyard(save_data)
    array_info(save_data, 'graveyard')
  end

  def waiting_room(save_data)
    array_info(save_data, 'waitingRoom')
  end

  def characters(save_data)
    array_info(save_data, 'characters')
  end

  def cards(card_mount, mount_name)
    array_info(card_mount, mount_name)
  end

  def array_info(hash, key)
    hash[key] ||= []
    hash[key]
  end

  def card_mount(save_data)
    hash_info(save_data, 'cardMount')
  end

  def hash_info(hash, key)
    hash[key] ||= {}
    hash[key]
  end


  def exit_waiting_room_character

    set_record_empty

    character_id = params['characterId']
    x            = params['x']
    y            = params['y']
    logging(character_id, 'exitWaitingRoomCharacter targetCharacterId')

    result = { "result" => "NG" }
    change_save_data(@savefiles['characters']) do |saveData|
      waiting_room = waiting_room(saveData)

      character_data = remove_from_array(waiting_room) do |character|
        character['imgId'] == character_id
      end

      logging(character_data, "exitWaitingRoomCharacter CharacterData")
      return result if (character_data.nil?)

      character_data['x'] = x
      character_data['y'] = y

      characters = characters(saveData)
      characters << character_data
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
    round_time_data = params
    change_initiative_data(round_time_data)

    return nil
  end

  def change_initiative_data(round_time_data)
    change_save_data(@savefiles['time']) do |saveData|
      saveData['roundTimeData'] = round_time_data
    end
  end


  def move_character
    change_save_data(@savefiles['characters']) do |saveData|

      character_move_data = params
      logging(character_move_data, "moveCharacter() characterMoveData")

      logging(character_move_data['imgId'], "character.imgId")

      characters = characters(saveData)

      characters.each do |characterData|
        next unless (characterData['imgId'] == character_move_data['imgId'])

        characterData['x'] = character_move_data['x']
        characterData['y'] = character_move_data['y']

        break
      end

      logging(characters, "after moved characters")

    end

    return nil
  end

  #override
  def savefile_timestamp(savefile_name)
    unless File.exist?(savefile_name)
      return 0
    end

    timestamp = File.mtime(savefile_name).to_f
  end

  def savefile_timestamp_millisec(savefile_name)
    (savefile_timestamp(savefile_name) * 1000).to_i
  end

  def savefile_changed?(last_update_time, savefile_name)
    last_update_time   = last_update_time.to_i
    savefile_timestamp = savefile_timestamp_millisec(savefile_name)
    changed            = (savefile_timestamp != last_update_time)

    logging(savefile_name, "saveFileName")
    logging(savefile_timestamp.inspect, "saveFileTimeStamp")
    logging(last_update_time.inspect, "lastUpdateTime   ")
    logging(changed, "changed")

    changed
  end

  def response_body
    if isJsonResult
      DodontoFServer::build_json(execute_command)
    else
      DodontoFsServer::build_msgpack(execute_command)
    end
  end
end


def error_response_body(e)
  <<-ERR
e.to_s : #{e.to_s}
e.inspect : #{e.inspect}
$@ : #{$@.join("\n")}
$! : #{$!.to_s("\n")}
  ERR
end


def compress?(result, server)
  return false if ($gzipTargetSize <= 0)
  return false if (server.jsonp_callback)

  (/gzip/ =~ ENV["HTTP_ACCEPT_ENCODING"]) and (result.length > $gzipTargetSize)
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
  logging "main called"

  server = DodontoFServer.new(SaveDirInfo.new, params)
  logging "server created"

  print_response(server)
  logging "printResult called"
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
  logging "========================================>CGI begin."

  body   = "empty"
  header = response_header(server)

  begin
    result = server.response_body
    result = "#D@EM>##{result}#<D@EM#" if server.is_add_marker
    result = "#{server.jsonp_callback}(#{result})" if server.jsonp_callback

    logging(result.length.to_s, "CGI response original length")

    if compress?(result, server)
      if $isModRuby
        Apache.request.content_encoding = 'gzip'
      else
        header << "Content-Encoding: gzip\n"
        header << "Access-Control-Allow-Origin: *\n" if server.jsonp_callback
      end
      body = compress_response(result)
    else
      body = result
    end
  rescue Exception => e
    error_message = error_response_body(e)
    loggingForce(error_message, "errorMessage")

    body = "\n"
    body << "= ERROR ====================\n"
    body << error_message
    body << "============================\n"
  end

  logging(header, "RESPONSE header")

  output = $stdout
  output.binmode if (defined?(output.binmode))
  output.print(header + "\n")
  output.print(body)

  logging "========================================>CGI end."
end


def extract_params_in_cgi
  logging "getCgiParams Begin"

  content_length = ENV['CONTENT_LENGTH'].to_i

  logging content_length, "getCgiParams length"

  input = nil
  if ENV['REQUEST_METHOD'] == "POST"
    input = $stdin.read(content_length)
  else
    input = ENV['QUERY_STRING']
  end

  logging input, "getCgiParams input"
  params = DodontoFServer::parse_msgpack(input)

  logging params, "messagePackedData"
  logging "getCgiParams End"

  params
end

if $0 === __FILE__

  initLog

  case $dbType
    when "mysql"
      #mod_ruby でも再読み込みするようにloadに
      require 'DodontoFServerMySql.rb'
      mainMySql(extract_params_in_cgi)
    else
      #通常のテキストファイル形式
      main(extract_params_in_cgi)
  end

end
