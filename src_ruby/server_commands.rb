# encoding:utf-8
require_relative 'configure'
require_relative 'loggingFunction'

# DodontoFServer.rbからCommand系のメソッドを抽出したModule.
# 切り分けのたたき台としてとりあえず作成
module ServerCommands

  # DodontoFServerで定義されているCommandList
  # ['key_name', 'method_name']
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
  }.freeze

  def refresh
    save_data = {}

    if Configure.is_mentenance
      save_data['warning'] = { :key => 'canNotRefreshBecauseMaintenanceNow' }
      return save_data
    end

    @last_update_times = params[:times]
    refresh_index = params[:rIndex]
    @isGetOwnRecord = params[:isGetOwnRecord]

    if Configure.is_comet
      refresh_routine(save_data)
    else
      refresh_once(save_data)
    end

    unique_id  = command_sender
    user_name  = params[:name]
    is_visitor = params[:isVisiter]

    login_user_info = login_user_info(user_name, unique_id, is_visitor)

    unless save_data.empty?
      save_data[:lastUpdateTimes] = @last_update_times
      save_data[:refreshIndex]    = refresh_index
      save_data[:loginUserInfo]   = login_user_info
    end

    save_data[:isFirstChatRefresh] = true if @last_update_times[:chatMessageDataLog] == 0

    save_data
  end

  def character_data_in_graveyard
    logging('getGraveyardCharacterData start.')
    result = []

    save_data(@savedir_info.save_files.characters) do |saveData|
      graveyard = saveData['graveyard']
      graveyard ||= []

      result = graveyard.reverse
    end

    result
  end

  def resurrect_character
    img_id = params['imgId']
    logging(img_id, 'resurrectCharacterId')

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      _graveyard = graveyard(saveData)

      character_data = remove_from_array(_graveyard) do |character|
        character['imgId'] == img_id
      end

      logging(character_data, 'resurrectCharacter CharacterData')
      return if (character_data.nil?)

      characters = characters(saveData)
      characters << character_data
    end

    nil
  end

  def clear_graveyard
    logging('clearGraveyard begin')

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      graveyard = graveyard(saveData)
      graveyard.clear
    end

    nil
  end

  def login_info

    unique_id = action_params[:uniqueId] || (Time.now.to_f * 1000).to_i.to_s(36)

    total_count, login_user_count_list = all_login_count
    write_all_login_info(total_count)

    {
        :loginMessage               => login_message,
        :cardInfos                  => CardDecks.collect_display_infos,
        :isDiceBotOn                => Configure.is_dicebot,
        :uniqueId                   => unique_id,
        :refreshTimeout             => Configure.refresh_timeout,
        :refreshInterval            => Configure.refresh_interval,
        :isCommet                   => Configure.is_comet,
        :version                    => Configure.version,
        :playRoomMaxNumber          => Configure.save_data_max_count - 1,
        :warning                    => login_warning,
        :playRoomGetRangeMax        => Configure.play_room_get_range_max,
        :allLoginCount              => total_count.to_i,
        :limitLoginCount            => Configure.limit_login_count,
        :loginUserCountList         => login_user_count_list,
        :maxLoginCount              => Configure.about_max_login_count,
        :skinImage                  => Configure.skin_image,
        :isPaformanceMonitor        => Configure.is_paformance_monitor,
        :fps                        => Configure.fps,
        :loginTimeLimitSecond       => Configure.login_time_limit_second,
        :removeOldPlayRoomLimitDays => Configure.remove_old_play_room_limit_days,
        :canTalk                    => Configure.can_talk,
        :retryCountLimit            => Configure.retry_count_limit,
        :imageUploadDirInfo         => { Configure.local_upload_dir_marker => Configure.image_upload_dir },
        :mapMaxWidth                => Configure.map_max_width,
        :mapMaxHeigth               => Configure.map_max_heigth,
        :diceBotInfos               => dicebot_infos,
        :isNeedCreatePassword       => (not Configure.create_play_room_password.empty?),
        :defaultUserNames           => Configure.default_user_names,
    }
  end

  def play_room_states
    logging(params, 'params')

    min_room         = min_room(params)
    max_room         = max_room(params)
    play_room_states = play_room_states_local(min_room, max_room)

    result = {
        :min_room       => min_room,
        :max_room       => max_room,
        :playRoomStates => play_room_states,
    }

    logging(result, 'getPlayRoomStatesLocal result')

    result
  end

  def play_room_states_by_count
    logging(params, 'params')

    min_room         = min_room(params)
    count            = params['count']
    play_room_states = play_room_states_by_count_local(min_room, count)

    result = {
        :playRoomStates => play_room_states,
    }

    logging(result, 'getPlayRoomStatesByCount result')

    result
  end

  def delete_image
    logging('deleteImage begin')

    image_data = params
    logging(image_data, 'imageData')

    url_list = image_data['imageUrlList']
    logging(url_list, 'imageUrlList')

    image_files = all_image_file_name_from_tag_info_file
    add_local_image_to_list(image_files)
    logging(image_files, 'imageFiles')

    url_file_name = SaveData::IMG_URL_TEXT
    logging(url_file_name, 'imageUrlFileName')

    complete_count = 0
    result_text    = ''
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
    result      = { :resultText => result_text }
    logging(result, 'result')

    logging('deleteImage end')
    result
  end

  def upload_image_url
    logging('uploadImageUrl begin')

    image_data = params
    logging(image_data, 'imageData')

    image_url = image_data['imageUrl']
    logging(image_url, 'imageUrl')

    image_url_text = SaveData::IMG_URL_TEXT
    logging(image_url_text, 'imageUrlFileName')

    result_text = '画像URLのアップロードに失敗しました。'
    locker      = savefile_lock(image_url_text)
    locker.in_action do
      exists_urls = File.readlines(image_url_text).collect { |i| i.chomp }
      if exists_urls.include?(image_url)
        result_text = 'すでに登録済みの画像URLです。'
      else
        add_text_to_file(image_url_text, (image_url + "\n"))
        result_text = '画像URLのアップロードに成功しました。'
      end
    end

    tag_info = image_data['tagInfo']
    logging(tag_info, 'uploadImageUrl.tagInfo')
    change_image_tags_local(image_url, tag_info)

    logging('uploadImageUrl end')

    { "resultText" => result_text }
  end

  def save
    is_add_playroom_info = true
    extension            = request_data('extension')
    save_select_files(SaveData::DATA_FILE_NAMES.keys, extension, is_add_playroom_info)
  end

  def save_map
    extension    = request_data('extension')
    select_types = %w(map characters)
    save_select_files(select_types, extension)
  end

  def save_scenario
    logging('saveScenario begin')
    dir = room_local_space_dir_name
    make_dir(dir)

    @save_scenario_base_url      = params['baseUrl']
    chat_palette_savedata_string = params['chatPaletteSaveData']

    all_save_data = savedata_all_for_scenario
    all_save_data = move_all_images_to_dir(dir, all_save_data)
    make_chat_pallet_savefile(dir, chat_palette_savedata_string)
    make_scenario_default_savefile(dir, all_save_data)

    remove_old_scenario_file(dir)
    base_name     = get_new_savefile_base_name(DodontoFServer::FULL_BACKUP_BASE_NAME)
    scenario_file = make_scenario_file(dir, base_name)

    result                = {}
    result[:result]       = 'OK'
    result[:saveFileName] = scenario_file

    logging(result, 'saveScenario result')
    result
  end

  def load
    logging('saveData load() Begin')

    result = {}

    begin
      check_load

      set_record_empty

      logging(params, 'load params')

      json_data_string = params['fileData']
      logging(json_data_string, 'jsonDataString')

      result = load_from_json_data_string(json_data_string)
    rescue => e
      result[:resultText] = e.to_s
    end

    logging(result, 'load result')

    result
  end

  def load_scenario
    logging('loadScenario() Begin')
    check_load

    set_record_empty

    file_upload_dir = room_local_space_dir_name

    clear_dir(file_upload_dir)
    make_dir(file_upload_dir)

    file_max_size = Configure.scenario_data_max_size # Mbyte
    scenario_file = nil
    is_rename     = false

    result = upload_base_file(file_upload_dir, file_max_size, is_rename) do |fileNameFullPath, fileNameOriginal, result|
      scenario_file = fileNameFullPath
    end

    logging(result, 'uploadFileBase result')

    unless result[:resultText] == 'OK'
      return result
    end

    extend_savedata(scenario_file, file_upload_dir)

    chat_palette_savedata         = load_scenario_default_info(file_upload_dir)
    result['chatPaletteSaveData'] = chat_palette_savedata

    logging(result, 'loadScenario result')

    result
  end

  def dicebot_infos
    logging('getDiceBotInfos Begin')

    require 'diceBotInfos'
    dicebot_infos = DiceBotInfos.new.getInfos

    command_infos = game_command_infos

    command_infos.each do |commandInfo|
      logging(commandInfo, 'commandInfos.each commandInfos')
      dicebot_prefix(dicebot_infos, commandInfo)
    end

    logging(dicebot_infos, 'getDiceBotInfos diceBotInfos')

    dicebot_infos
  end

  def bot_table_infos
    logging('getBotTableInfos Begin')
    result = {
        :resultText => 'OK',
    }

    dir                 = dicebot_extra_table_dir_name
    result[:tableInfos] = get_bot_table_infos_from_dir(dir)

    logging(result, 'result')
    logging('getBotTableInfos End')
    result
  end

  def add_bot_table
    result              = {}
    result[:resultText] = add_bot_table_main

    if result[:resultText] != 'OK'
      return result
    end

    logging('addBotTableMain called')

    result = bot_table_infos
    logging(result, 'addBotTable result')

    result
  end

  def change_bot_table
    result              = {}
    result[:resultText] = change_bot_table_main

    if result[:resultText] != 'OK'
      return result
    end

    bot_table_infos
  end

  def remove_bot_table
    remove_bot_table_main
    bot_table_infos
  end

  def request_replay_data_list
    logging('requestReplayDataList begin')
    result = {
        :resultText => 'OK',
    }

    result[:replayDataList] = get_replay_data_list #[{"title"=>x, "url"=>y}]

    logging(result, 'result')
    logging('requestReplayDataList end')
    result
  end

  def upload_replay_data
    upload_base_file(Configure.replay_data_upload_dir, Configure.upload_replay_data_max_size) do |fileNameFullPath, fileNameOriginal, result|
      logging('uploadReplayData yield Begin')

      own_url    = params['ownUrl']
      replay_url = own_url + '?replay=' + CGI.escape(fileNameFullPath)

      replay_data_name = params['replayDataName']
      replay_data_info = set_replay_data_info(fileNameFullPath, replay_data_name, replay_url)

      result[:replayDataInfo] = replay_data_info
      result[:replayDataList] = get_replay_data_list #[{"title"=>x, "url"=>y}]

      logging('uploadReplayData yield End')
    end
  end

  def remove_replay_data
    logging('removeReplayData begin')

    result = {
        :resultText => 'NG',
    }

    begin
      replay_data = params

      logging(replay_data, 'replayData')

      replay_data_list = []
      change_save_data(get_replay_data_info_file_name) do |saveData|
        saveData['replayDataList'] ||= []
        replay_data_list           = saveData['replayDataList']

        replay_data_list.delete_if do |i|
          if (i['url'] == replay_data['url']) and (i['title'] == replay_data['title'])
            File.delete(i['fileName'])
            true
          else
            false
          end
        end
      end

      logging('removeReplayData replayDataList', replay_data_list)

      result = request_replay_data_list
    rescue => e
      result[:resultText] = e.to_s
      logging_exception(e)
    end

    result
  end

  def check_room_status
    delete_old_upload_file

    check_room_status_data = params
    logging(check_room_status_data, 'checkRoomStatusData')

    room_number = check_room_status_data['roomNumber']
    logging(room_number, 'roomNumber')

    @savedir_info.dir_index(room_number)

    is_maintenance_on      = false
    is_welcome_message_on  = Configure.is_welcome_message
    play_room_name         = ''
    chat_channel_names     = nil
    can_use_external_image = false
    can_visit              = false
    is_password_locked     = false
    true_savefile_name     = @savedir_info.real_savefile_name(SaveData::PLAY_ROOM_INFO_FILE)
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

    unless Configure.mentenance_mode_password.nil?
      if check_room_status_data['adminPassword'] == Configure.mentenance_mode_password
        is_password_locked    = false
        is_welcome_message_on = false
        is_maintenance_on     = true
      end
    end

    logging(:isPasswordLocked, is_password_locked)

    result = {
        :isRoomExist         => is_exist_playroom_info,
        :roomName            => play_room_name,
        :roomNumber          => room_number,
        :chatChannelNames    => chat_channel_names,
        :canUseExternalImage => can_use_external_image,
        :canVisit            => can_visit,
        :isPasswordLocked    => is_password_locked,
        :isMentenanceModeOn  => is_maintenance_on,
        :isWelcomeMessageOn  => is_welcome_message_on,
    }

    logging(result, 'checkRoomStatus End result')

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

  def upload_file
    upload_base_file(Configure.file_upload_dir, Configure.upload_file_max_size) do |fileNameFullPath, fileNameOriginal, result|

      delete_old_upload_file

      base_url = params['baseUrl']
      logging(base_url, 'baseUrl')

      file_upload_url = base_url + fileNameFullPath

      result[:uploadFileInfo] = {
          :fileName      => fileNameOriginal,
          :fileUploadUrl => file_upload_url,
      }
    end
  end

  def upload_image_data
    logging 'uploadImageData load Begin'

    result = {
        :resultText => 'OK'
    }

    begin

      image_file_name = params['imageFileName']
      logging(image_file_name, 'imageFileName')

      image_data       = image_data_in_params(params, 'imageData')
      small_image_data = image_data_in_params(params, 'smallImageData')

      if image_data.nil?
        logging('createSmallImage is here')
        image_file_base_name = File.basename(image_file_name)
        save_small_image(small_image_data, image_file_base_name, image_file_name)
        return result
      end

      save_dir             = Configure.image_upload_dir
      image_file_base_name = new_file_name(image_file_name, 'img')
      logging(image_file_base_name, 'imageFileNameBase')

      upload_image_file_name = File.join(save_dir, image_file_base_name)
      logging(upload_image_file_name, 'uploadImageFileName')

      open(upload_image_file_name, 'wb+') do |file|
        file.write(image_data)
      end

      save_small_image(small_image_data, image_file_base_name, upload_image_file_name)
    rescue => e
      result[:resultText] = e.to_s
    end

    result
  end

  #新規PlayRoom作成
  def create_play_room
    logging('createPlayRoom begin')

    result_text     = 'OK'
    play_room_index = nil
    begin
      logging(params, 'params')

      check_create_play_room_password(params['createPassword'])

      play_room_name         = params['playRoomName']
      play_room_password     = params['playRoomPassword']
      play_room_index        = params['playRoomIndex']

      unless play_room_index
        play_room_index = find_empty_room_number
        raise Exception.new('noEmptyPlayRoom') unless play_room_index
        logging(play_room_index, 'findEmptyRoomNumber playRoomIndex')
      end

      logging(play_room_name, 'playRoomName')
      logging('playRoomPassword is get')
      logging(play_room_index, 'playRoomIndex')

      @savedir_info = SaveData.new(play_room_index)
      check_set_password(play_room_password, play_room_index)

      logging('@saveDirInfo.removeSaveDir(playRoomIndex) Begin')
      @savedir_info.remove_dir
      logging('@saveDirInfo.removeSaveDir(playRoomIndex) End')

      @savedir_info.create_dir

      play_room_changed_password = changed_password(play_room_password)
      logging(play_room_changed_password, 'playRoomChangedPassword')

      logging('viewStates', params['viewStates'])

      playroom_info_file_path = @savedir_info.save_file_path(SaveData::PLAY_ROOM_INFO_FILE)

      change_save_data(playroom_info_file_path) do |saveData|
        saveData['playRoomName']            = play_room_name
        saveData['playRoomChangedPassword'] = play_room_changed_password
        saveData['chatChannelNames']        = params['chatChannelNames']
        saveData['canUseExternalImage']     = params['canUseExternalImage']
        saveData['canVisit']                = params['canVisit']
        saveData['gameType']                = params['gameType']

        add_view_states_to_savedata(saveData, params['viewStates'])
      end

      send_room_create_message(play_room_index)
    rescue => e
      logging_exception(e)
      result_text = e.inspect + '$@ : ' + $@.join("\n")
    rescue Exception => errorMessage
      result_text = errorMessage.to_s
    end

    result = {
        :resultText    => result_text,
        :playRoomIndex => play_room_index,
    }
    logging(result, 'result')
    logging('createDir finished')

    result
  end

  def change_play_room
    logging 'changePlayRoom begin'

    result_text = 'OK'

    begin
      logging(params, 'params')

      play_room_password = params['playRoomPassword']
      check_set_password(play_room_password)

      play_room_changed_password = changed_password(play_room_password)
      logging('playRoomPassword is get')

      view_states = params['viewStates']
      logging('viewStates', view_states)

      real_savefile_name = @savedir_info.real_savefile_name(SaveData::PLAY_ROOM_INFO_FILE)

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
        :resultText => result_text,
    }
    logging(result, 'changePlayRoom result')

    result
  end

  def remove_play_room

    room_numbers      = params['roomNumbers']
    ignore_login_user = params['ignoreLoginUser']
    password          = params['password'] || ''

    remove_play_room_by_params(room_numbers, ignore_login_user, password)
  end

  def remove_old_play_room
    all_range    = (0 .. Configure.save_data_max_count)
    access_times = SaveData::save_data_last_access_times(SaveData::DATA_FILE_NAMES.values, all_range)
    remove_old_room_for_access_times(access_times)
  end

  def image_tags_and_image_list
    result = {}

    result['tagInfos']  = image_tags
    result['imageList'] = image_list
    result['imageDir']  = Configure.image_upload_dir

    logging('getImageTagsAndImageList result', result)

    result
  end

  def add_character
    character_data      = params
    character_data_list = [character_data]

    add_character_data(character_data_list)
  end

  def waiting_room_info
    logging('getWaitingRoomInfo start.')
    result = []

    save_data(@savedir_info.save_files.characters) do |saveData|
      waiting_room = waiting_room(saveData)
      result       = waiting_room
    end

    result
  end

  def exit_waiting_room_character

    set_record_empty

    character_id = params['characterId']
    x            = params['x']
    y            = params['y']
    logging(character_id, 'exitWaitingRoomCharacter targetCharacterId')

    result = { :result => 'NG' }
    change_save_data(@savedir_info.save_files.characters) do |saveData|
      waiting_room = waiting_room(saveData)

      character_data = remove_from_array(waiting_room) do |character|
        character['imgId'] == character_id
      end

      logging(character_data, 'exitWaitingRoomCharacter CharacterData')
      return result if (character_data.nil?)

      character_data['x'] = x
      character_data['y'] = y

      characters = characters(saveData)
      characters << character_data
    end

    result[:result] = 'OK'
    result
  end

  def enter_waiting_room_character

    set_record_empty

    character_id = params['characterId']

    logging(character_id, 'enterWaitingRoomCharacter characterId')

    result = { :result => 'NG' }
    change_save_data(@savedir_info.save_files.characters) do |saveData|
      characters = characters(saveData)

      enter_character_data = remove_from_array(characters) { |i| (i['imgId'] == character_id) }
      return result if (enter_character_data.nil?)

      waiting_room = waiting_room(saveData)
      waiting_room << enter_character_data
    end

    result[:result] = 'OK'
    result
  end

  def send_dicebot_chat_message
    logging 'sendDiceBotChatMessage'

    repeat_count = dicebot_repeat_count(params)

    message = params['message']

    results = []
    repeat_count.times do |i|
      message_once = message

      if repeat_count > 1
        message_once = message + ' #' + (i + 1).to_s
      end

      logging(message_once, 'sendDiceBotChatMessage oneMessage')
      result = send_dicebot_chat_message_once(params, message_once)
      logging(result, 'sendDiceBotChatMessageOnece result')

      next if (result.nil?)
      results << result
    end

    logging(results, 'sendDiceBotChatMessage results')

    results
  end

  def delete_chat_log
    true_savefile_name = @savedir_info.save_files.chatMessageDataLog
    delete_chat_log_by_savefile(true_savefile_name)

    { :result => 'OK' }
  end

  def send_chat_message_all
    logging('sendChatMessageAll Begin')

    result = { :result => 'NG' }

    return result if (Configure.mentenance_mode_password.nil?)
    chat_data = params

    password = chat_data['password']
    logging(password, 'password check...')
    return result unless (password == Configure.mentenance_mode_password)

    logging('adminPassword check OK.')

    rooms = []

    Configure.save_data_max_count.times do |roomNumber|
      logging(roomNumber, 'loop roomNumber')

      init_savefiles(roomNumber)

      true_savefile_name = @savedir_info.real_savefile_name(SaveData::PLAY_ROOM_INFO_FILE)
      next unless (File.exist?(true_savefile_name))

      logging(roomNumber, 'sendChatMessageAll to No.')
      send_chat_message_by_chat_data(chat_data)

      rooms << roomNumber
    end

    result['result'] = 'OK'
    result['rooms']  = rooms
    logging(result, 'sendChatMessageAll End, result')

    result
  end

  def undo_draw_on_map
    result = {
        :data => nil
    }

    change_save_data(@savedir_info.save_files.map) do |saveData|
      draws         = draws(saveData)
      result[:data] = draws.pop
    end

    result
  end

  def logout
    logout_data = params
    logging(logout_data, 'logoutData')

    unique_id = logout_data['uniqueId']
    logging(unique_id, 'uniqueId')

    true_savefile_name = @savedir_info.real_savefile_name(SaveData::LOGIN_FILE)
    change_save_data(true_savefile_name) do |saveData|
      saveData.each do |existUserId, userInfo|
        logging(existUserId, 'existUserId in logout check')
        logging(unique_id, 'uniqueId in logout check')

        if existUserId == unique_id
          userInfo['isLogout'] = true
        end
      end

      logging(saveData, 'saveData in logout')
    end

    return nil
  end

  def change_character
    character_data = params
    logging(character_data.inspect, 'characterData')

    change_character_data(character_data)

    return nil
  end

  def remove_character
    remove_character_list = params
    remove_character_by_remove_character_data_list(remove_character_list)

    return nil
  end

  def mount_card_infos
    logging(params, 'getTrushMountCardInfos params')

    mount_name = params['mountName']
    mount_id   = params['mountId']

    cards = []

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      card_mount = card_mount(saveData)
      cards      = cards(card_mount, mount_name)

      card_mount_data         = find_card_mount_data(saveData, mount_id)
      card_count_display_diff = card_mount_data['cardCountDisplayDiff']

      logging(card_count_display_diff, 'cardCountDisplayDiff')
      logging(cards.length, 'before cards.length')

      unless card_count_display_diff.nil?
        unless cards.empty?
          cards = cards[card_count_display_diff .. -1]
        end
      end

    end

    logging(cards.length, 'getMountCardInfos cards.length')

    cards
  end

  def trash_mount_card_infos

    logging(params, 'getTrushMountCardInfos params')

    mount_name = params['mountName']
    mount_id   = params['mountId']

    cards = []

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)
      cards                    = trash_cards
    end

    cards
  end

  def draw_target_card
    logging('drawTargetCard Begin')

    set_no_body_sender

    logging(params, 'params')

    mount_name = params['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savedir_info.save_files.characters) do |saveData|
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

    logging('drawTargetCard End')

    { :result => 'OK' }
  end

  def draw_target_trash_card
    logging('drawTargetTrushCard Begin')

    set_no_body_sender

    mount_name = params['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savedir_info.save_files.characters) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      card_data = remove_from_array(trash_cards) { |i| i['imgId'] === params['targetCardId'] }
      logging(card_data, 'cardData')
      return if (card_data.nil?)

      card_data['x'] = params['x']
      card_data['y'] = params['y']

      characters = characters(saveData)
      characters.push(card_data)

      trash_mount_data = find_card_data(characters, params['mountId'])
      logging(trash_mount_data, 'returnCard trushMountData')

      return if (trash_mount_data.nil?)

      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)
    end

    logging('drawTargetTrushCard End')

    { :result => 'OK' }
  end

  def draw_card
    logging('drawCard Begin')

    set_no_body_sender

    logging(params, 'params')

    result = { :result => 'NG' }

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      count = params['count']

      count.times do
        draw_card_data_one(params, saveData)
      end

      result[:result] = 'OK'
    end

    logging('drawCard End')

    result
  end

  def add_card
    logging('addCard begin')

    add_card_data = params

    is_text         = add_card_data['isText']
    image_name      = add_card_data['imageName']
    image_name_back = add_card_data['imageNameBack']
    mount_name      = add_card_data['mountName']
    is_up_down      = add_card_data['isUpDown']
    can_delete      = add_card_data['canDelete']
    is_open         = add_card_data['isOpen']
    is_back         = add_card_data['isBack']

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      card_data      = card_data(is_text, image_name, image_name_back, mount_name, is_up_down, can_delete)
      card_data['x'] = add_card_data['x']
      card_data['y'] = add_card_data['y']
      card_data['isOpen'] = is_open unless (is_open.nil?)
      card_data['isBack'] = is_back unless (is_back.nil?)

      characters = characters(saveData)
      characters << card_data
    end

    logging('addCard end')

    return nil
  end

  def add_card_zone
    logging('addCardZone Begin')

    data = params

    x          = data['x']
    y          = data['y']
    owner      = data['owner']
    owner_name = data['ownerName']

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      characters = characters(saveData)
      logging(characters, 'addCardZone characters')

      card_data = card_zone_data(owner, owner_name, x, y)
      characters << card_data
    end

    logging('addCardZone End')
    return nil
  end

  def init_cards
    logging('initCards Begin')

    set_record_empty

    clear_character_by_type_local(DodontoFServer::CARD_TYPE)
    clear_character_by_type_local(DodontoFServer::CARD_MOUNT_TYPE)
    clear_character_by_type_local(DodontoFServer::DUNGEON_MOUNT_TYPE)
    clear_character_by_type_local(DodontoFServer::CARD_ZONE_TYPE)
    clear_character_by_type_local(DodontoFServer::CARD_TRASH_TYPE)
    clear_character_by_type_local(DodontoFServer::DUNGEON_TRASH_TYPE)

    card_type_infos = params['cardTypeInfos']
    logging(card_type_infos, 'cardTypeInfos')

    change_save_data(@savedir_info.save_files.characters) do |saveData|
      saveData['cardTrushMount'] = {}

      saveData['cardMount'] = {}
      card_mounts           = saveData['cardMount']

      characters = characters(saveData)
      logging(characters, 'initCards saveData.characters')

      card_type_infos.each_with_index do |cardTypeInfo, index|
        mount_name = cardTypeInfo['mountName']
        logging(mount_name, 'initCards mountName')

        cards_list_file_name = CardDecks.file_name(mount_name)
        logging(cards_list_file_name, 'initCards cardsListFileName')

        cards_list = []
        File.readlines(cards_list_file_name).each_with_index do |i, lineIndex|
          cards_list << i.chomp.toutf8
        end

        logging(cards_list, 'initCards cardsList')

        card_data  = cards_list.shift.split(/,/)
        is_text    = (card_data.shift == 'text')
        is_up_down = (card_data.shift == 'upDown')
        logging('isUpDown', is_up_down)
        image_name_back = cards_list.shift

        cards_list, is_sorted   = initialize_card_set(cards_list, cardTypeInfo)
        card_mounts[mount_name] = initialized_card_mount(cards_list, mount_name, is_text, is_up_down, image_name_back, is_sorted)

        card_mount_data = create_card_mount_data(card_mounts, is_text, image_name_back, mount_name, index, is_up_down, cardTypeInfo, cards_list)
        characters << card_mount_data

        card_trash_mount_data = card_trash_mount_data(is_text, mount_name, index, cardTypeInfo)
        characters << card_trash_mount_data
      end

      wait_for_refresh = 0.2
      sleep(wait_for_refresh)
    end

    logging('initCards End')

    card_exist = (not card_type_infos.empty?)
    { :result => 'OK', :cardExist => card_exist }
  end

  def return_card
    logging('returnCard Begin')

    set_no_body_sender

    mount_name = params['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savedir_info.save_files.characters) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      card_data = trash_cards.pop
      logging(card_data, 'cardData')
      if card_data.nil?
        logging('returnCard trushCards is empty. END.')
        return
      end

      card_data['x'] = params['x'] + 150
      card_data['y'] = params['y'] + 10
      logging('returned cardData', card_data)

      characters = characters(saveData)
      characters.push(card_data)

      trash_mount_data = find_card_data(characters, params['imgId'])
      logging(trash_mount_data, 'returnCard trushMountData')

      return if (trash_mount_data.nil?)

      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)
    end

    logging('returnCard End')

    return nil
  end

  def shuffle_cards
    logging 'shuffleCard Begin'

    set_record_empty

    mount_name     = params['mountName']
    trash_mount_id = params['mountId']
    is_shuffle     = params['isShuffle']

    logging(mount_name, 'mountName')
    logging(trash_mount_id, 'trushMountId')

    change_save_data(@savedir_info.save_files.characters) do |saveData|

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

      card_mount_data = find_card_mount_data_by_type(characters, mount_name, DodontoFServer::CARD_MOUNT_TYPE)
      return if (card_mount_data.nil?)

      if is_shuffle
        is_up_down  = card_mount_data['isUpDown']
        mount_cards = shuffle_mount(mount_cards, is_up_down)
      end

      card_mount[mount_name] = mount_cards
      saveData['cardMount']  = card_mount

      set_card_count_and_back_image(card_mount_data, mount_cards)
    end

    logging 'shuffleCard End'
    return nil
  end

  def shuffle_next_random_dungeon
    logging 'shuffleForNextRandomDungeon Begin'

    set_record_empty

    mount_name     = params['mountName']
    trash_mount_id = params['mountId']

    logging(mount_name, 'mountName')
    logging(trash_mount_id, 'trushMountId')

    change_save_data(@savedir_info.save_files.characters) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)
      logging(trash_cards.length, 'trushCards.length')

      saveData['cardMount']  ||= {}
      card_mount             = saveData['cardMount']
      card_mount[mount_name] ||= []
      mount_cards            = card_mount[mount_name]

      characters      = characters(saveData)
      card_mount_data = find_card_mount_data_by_type(characters, mount_name, DodontoFServer::DUNGEON_MOUNT_TYPE)
      return if (card_mount_data.nil?)

      ace_list = card_mount_data['aceList']
      logging(ace_list, 'aceList')

      ace_cards = []
      ace_cards += delete_ace_from_cards(trash_cards, ace_list)
      ace_cards += delete_ace_from_cards(mount_cards, ace_list)
      ace_cards += delete_ace_from_cards(characters, ace_list)
      ace_cards = ace_cards.sort_by { rand }

      logging(ace_cards, 'aceCards')
      logging(trash_cards.length, 'trushCards.length')
      logging(mount_cards.length, 'mountCards.length')

      use_count = card_mount_data['useCount']
      if (mount_cards.size + 1) < use_count
        use_count = (mount_cards.size + 1)
      end

      mount_cards = mount_cards.sort_by { rand }

      insert_point = rand(use_count)
      logging(insert_point, 'insertPoint')
      mount_cards[insert_point, 0] = ace_cards.shift

      while ace_cards.length > 0
        mount_cards[use_count, 0] = ace_cards.shift
        logging(use_count, 'useCount')
      end

      mount_cards = mount_cards.reverse

      card_mount[mount_name] = mount_cards
      saveData['cardMount']  = card_mount

      new_diff = mount_cards.size - use_count
      new_diff = 3 if (new_diff < 3)
      logging(new_diff, 'newDiff')
      card_mount_data['cardCountDisplayDiff'] = new_diff


      trash_mount_data = find_card_data(characters, trash_mount_id)
      return if (trash_mount_data.nil?)
      set_trash_mount_data_cards_info(saveData, trash_mount_data, trash_cards)

      set_card_count_and_back_image(card_mount_data, mount_cards)
    end

    logging('shuffleForNextRandomDungeon End')

    return nil
  end

  def dump_trash_cards
    logging('dumpTrushCards Begin')

    set_no_body_sender

    dump_trash_cards = params
    logging(dump_trash_cards, 'dumpTrushCardsData')

    mount_name = dump_trash_cards['mountName']
    logging(mount_name, 'mountName')

    change_save_data(@savedir_info.save_files.characters) do |saveData|

      trash_mount, trash_cards = find_trash_mount_and_cards(saveData, mount_name)

      characters = characters(saveData)

      dumped_card_id = dump_trash_cards['dumpedCardId']
      logging(dumped_card_id, 'dumpedCardId')

      logging(characters.size, 'characters.size before')
      card_data = delete_find_one(characters) { |i| i['imgId'] === dumped_card_id }
      trash_cards << card_data
      logging(characters.size, 'characters.size after')

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

    logging('dumpTrushCards End')
    return nil
  end

  def clear_character_by_type
    logging 'clearCharacterByType Begin'

    set_record_empty

    clear_data = params
    logging(clear_data, 'clearData')

    target_types = clear_data['types']
    logging(target_types, 'targetTypes')

    target_types.each do |targetType|
      clear_character_by_type_local(targetType)
    end

    logging 'clearCharacterByType End'

    return nil
  end

  def move_character
    change_save_data(@savedir_info.save_files.characters) do |saveData|

      character_move_data = params
      logging(character_move_data, 'moveCharacter() characterMoveData')

      logging(character_move_data['imgId'], 'character.imgId')

      characters = characters(saveData)

      characters.each do |characterData|
        next unless (characterData['imgId'] == character_move_data['imgId'])

        characterData['x'] = character_move_data['x']
        characterData['y'] = character_move_data['y']

        break
      end

      logging(characters, 'after moved characters')

    end

    return nil
  end

  def change_map
    map_data = params
    logging(map_data, 'mapData')

    change_map_savedata(map_data)

    return nil
  end

  def draw_on_map
    logging('drawOnMap Begin')

    data = params['data']
    logging(data, 'data')

    change_save_data(@savedir_info.save_files.map) do |saveData|
      set_draws(saveData, data)
    end

    logging('drawOnMap End')

    return nil
  end

  def clear_draw_on_map
    change_save_data(@savedir_info.save_files.map) do |saveData|
      draws = draws(saveData)
      draws.clear
    end

    return nil
  end

  def send_chat_message
    chat_data = params
    send_chat_message_by_chat_data(chat_data)

    return nil
  end

  def change_round_time
    round_time_data = params
    change_initiative_data(round_time_data)

    return nil
  end

  def add_effect
    effect_data      = params
    effect_data_list = [effect_data]
    add_effect_data(effect_data_list)

    return nil
  end

  def change_effect
    change_save_data(@savedir_info.save_files.effects) do |saveData|
      effect_data      = params
      target_cut_in_id = effect_data['effectId']

      saveData['effects'] ||= []
      effects             = saveData['effects']

      find_index = -1
      effects.each_with_index do |i, index|
        if target_cut_in_id == i['effectId']
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

    change_save_data(@savedir_info.save_files.effects) do |saveData|

      effect_id = params['effectId']
      logging(effect_id, 'effectId')

      saveData['effects'] ||= []
      effects             = saveData['effects']
      effects.delete_if { |i| (effect_id == i['effectId']) }
    end

    logging('removeEffect End')

    return nil
  end

  def change_image_tags
    effect_data = params
    source      = effect_data['source']
    tag_info    = effect_data['tagInfo']

    change_image_tags_local(source, tag_info)

    return nil
  end
end