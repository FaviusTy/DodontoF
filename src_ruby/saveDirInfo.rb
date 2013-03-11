# encoding: utf-8

require 'fileutils'
require File.dirname(__FILE__) + '/configure'


class SaveData

  attr_accessor :dir_index, :sample_mode
  attr_reader :save_files

  # saveDataディレクトリまでの相対パス
  SUB_DIR             = Configure.save_data_dir
  # プレイルームの最大数
  MAX_NUMBER          = Configure.save_data_max_count
  # ディレクトリ名の共通プリフィクス
  PREFIX_DIR_NAME     = 'data_'
  # TODO:RESEARCH 元$saveFileNamesさん. 用途不特定
  SAVE_FILE_NAMES     = File.join(Configure.save_data_temp_dir, 'saveFileNames.json')
  # TODO:RESEARCH 元$imageUrlTextさん. 用途不特定
  IMG_URL_TEXT        = File.join(Configure.image_upload_dir, 'imageUrl.txt')
  # TODO:RESEARCH 元$chatMessageDataLogAllさん. 用途不特定
  CHAT_LONG_LINE_FILE = 'chatLongLines.txt'
  # TODO:RESEARCH 元$loginUserInfoさん
  LOGIN_FILE          = 'login.json'
  # TODO:RESEARCH 元$playRoomInfoさん
  PLAY_ROOM_INFO      = 'playRoomInfo'
  # TODO:RESEARCH 元$playRoomInfoTypeNameさん
  PLAY_ROOM_INFO_FILE = "#{PLAY_ROOM_INFO}.json"
  # TODO:RESEARCH 元$saveFilesさん
  FILE_NAME_SET       = {
      :chatMessageDataLog  => 'chat.json',
      :map                 => 'map.json',
      :characters          => 'characters.json',
      :time                => 'time.json',
      :effects             => 'effects.json',
      :"#{PLAY_ROOM_INFO}" => PLAY_ROOM_INFO_FILE,
  }

  def initialize(index_obj)
    @sample_mode = false

    # dir_index生成
    dir_index = index_obj.instance_of?(StringIO) ? index_obj.string : index_obj
    unless @sample_mode
      raise "saveDataDirIndex:#{dir_index} is over Limit:(#{MAX_NUMBER})" if dir_index.to_i > MAX_NUMBER
    end
    @dir_index = dir_index.to_i

    # save_files生成
    files = {}
    SaveData::FILE_NAME_SET.each do |key_name, file_name|
      files[key_name] = File.join(data_dir_path, file_name)
    end
    @save_files = NestedOpenStruct.new(files)
  end

  # saveDataディレクトリまでのアクセスパスを返す
  def self.root_dir_path
    File.join(SUB_DIR, 'saveData')
  end

  def each_with_index(target_range, *file_names)
    dirs = SaveData::exist_data_dirs(target_range)

    dirs.each_with_index do |directory, _|
      next unless (/#{PREFIX_DIR_NAME}(\d+)\Z/ === directory)

      room_index = $1.to_i
      save_files = names_exist_file(directory, file_names)

      yield(save_files, room_index)
    end
  end

  # file_namesのうち、引数dir内に存在するファイルのファイル名のみをフィルタリングして返す
  def names_exist_file(dir, file_names)
    file_names.map { |file_name| File.join(dir, file_name) }
    .find_all { |file| FileTest.exist? file }
  end

  # target_range範囲内のindexのうち、ディレクトリが存在するものを返す
  def self.exist_data_dirs(target_range)
    dir_names = target_range.map { |i| "data_#{i}" }

    dir_names.map { |dir| File.join(self.root_dir_path, dir) }
    .find_all { |dir| FileTest.exist? dir }
  end

  # target_rangeの範囲内のdataディレクトリ別にfile_namesにあるファイル中で最新のtimestampを配列にして返す
  def self.save_data_last_access_times(file_names, target_range) #TODO:FIXME 委譲関係が逆.単体分の処理をtimeメソッドに委譲する方が自然
    data_dirs = exist_data_dirs(target_range)

    result = {}
    data_dirs.each do |saveDir|
      next unless (/#{PREFIX_DIR_NAME}(\d+)\Z/ === saveDir)

      room_index = $1.to_i
      next unless (target_range.include?(room_index))

      save_files         = names_exist_file(saveDir, file_names)
      m_times            = save_files.collect { |i| File.mtime(i) }
      result[room_index] = m_times.max
    end

    result
  end

  #このインスタンスが表すDataディレクトリまでのアクセスパスを返す
  def data_dir_path
    SaveData::data_dir_path(dir_index)
  end

  # 引数indexに対応するDataディレクトリまでのアクセスパスを返す
  def self.data_dir_path(index = 0)
    File.join(SaveData::root_dir_path, "data_#{index}") if index >= 0
  end

  # 新しいDataディレクトリとファイルセットを作成する
  def create_dir

    raise 'このプレイルームはすでに作成済みです。' if FileTest.directory?(data_dir_path)

    Dir::mkdir(data_dir_path)
    File.chmod(0777, data_dir_path)

    options = {
        :preserve => true,
    }

    file_names = SaveData::all_save_file_names
    src_files  = names_exist_file('saveData_forNewCreation', file_names)

    FileUtils.cp_r(src_files, data_dir_path, options)
  end

  # Dataディレクトリ内で管理されるファイル名のリストを返す.
  # リストには各ファイルのロック制御ファイルも含まれる
  def self.all_save_file_names
    file_names = []

    all_files = FILE_NAME_SET.values + [
        LOGIN_FILE,
        PLAY_ROOM_INFO_FILE,
        CHAT_LONG_LINE_FILE,
    ]

    all_files.each do |i|
      file_names << i
      file_names << "#{i}.lock"
    end

    file_names
  end

  def remove_dir(dir_index)
    dir_name = SaveData::data_dir_path(dir_index)
    SaveData::remove_dir(dir_name)
  end

  # TODO:FIXME dir_nameは実際にはフルパスであることを要求しているが、内部的に求められるはずなのでそのように改修する
  def self.remove_dir(dir_name)
    return unless (FileTest.directory?(dir_name))

    # force = true
    # FileUtils.remove_entry_secure(dirName, force)

    # 上記のメソッドは一部レンタルサーバ(さくらインターネット等）で禁止されているので、
    # この下の方法で対応しています。

    files = Dir.glob(File.join(dir_name, '*'))

    files.each do |fileName|
      File.delete(fileName.untaint)
    end

    Dir.delete(dir_name)
  end

  # file_nameが実在する場合、そのアクセスパスを返す
  def save_file_path(file_name)
    SaveData::save_file_path(file_name, dir_index)
  end

  def self.save_file_path(file_name, index = 0)
    file_path = File.join(self.data_dir_path(index), file_name)
    return file_path if FileTest.exist?(file_path) && FileTest.file?(file_path)
  end

end

# テストハーネス
if $0 === __FILE__
  require './loggingFunction'
  require 'stringio'

  # カレントディレクトリをDodontoFServer.rbの位置に変更
  Dir.chdir('../')

  save_data = SaveData.new(0)
  puts "saveData initialized : #{save_data}"

  puts 'statics call...'
  puts "SAVE_FILE_NAMES: #{SaveData::SAVE_FILE_NAMES}"
  puts "IMG_URL_TEXT: #{SaveData::IMG_URL_TEXT}"
  puts "CHAT_LONG_LINE_FILE: #{SaveData::CHAT_LONG_LINE_FILE}"
  puts "LOGIN_FILE: #{SaveData::LOGIN_FILE}"
  puts "PLAY_ROOM_INFO: #{SaveData::PLAY_ROOM_INFO}"
  puts "PLAY_ROOM_INFO_FILE: #{SaveData::PLAY_ROOM_INFO_FILE}"
  puts "FILE_NAME_SET: #{SaveData::FILE_NAME_SET}"

  puts 'field call...'
  puts "save_files: #{save_data.save_files}"

  puts 'method call...'
  puts "all_save_file_names : #{SaveData::all_save_file_names}"
  puts "root_dir_path : #{SaveData::root_dir_path}"
  puts "exist_data_dirs : #{SaveData::exist_data_dirs((0 .. 0))}"
  puts "data_dir_path : #{save_data.data_dir_path}"
  puts "real_save_file_name : #{save_data.save_file_path('.')}"
end