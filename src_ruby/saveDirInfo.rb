# encoding: utf-8

require 'fileutils'

class SaveDirInfo

  attr_reader :max_number

  def init(dir_index_obj, max_number = 0, sub_dir = '.')
    @dir_index_obj = dir_index_obj
    @dir_index     = nil
    @sub_dir       = sub_dir
    @max_number    = max_number
    @sample_mode   = false
  end

  def sample_mode_on #TODO:FIXME 参照先が1つも現存していない.削除候補
    @sample_mode = true
  end

  # saveDataのアクセスパスを返す => 通常は ./saveData
  def save_date_dir_base_path
    File.join(@sub_dir, "saveData")
  end

  def each_with_index(target_range, *file_names)
    dirs = save_data_dirs(target_range)

    dirs.each_with_index do |directory, index|
      next unless (/data_(\d+)\Z/ === directory)

      room_index = $1.to_i
      savefiles  = names_exist_file(directory, file_names)
      yield(savefiles, room_index)
    end
  end

  # file_namesのうち、引数dir内に存在するファイルのファイル名のみをフィルタリングして返す
  def names_exist_file(dir, file_names)

    file_names.find_all do |file|
      if FileTest.exist?(File.join(dir, file))
      end
    end

  end

  def save_data_dirs(target_range)
    dir       = save_date_dir_base_path
    dir_names = []
    target_range.each { |i| dir_names << File.join("data_" + i.to_s) }

    save_dirs = names_exist_file(dir, dir_names) #TODO:FIXME ディレクトリ抽出にfileとあるメソッド名を使うのはちょっと微妙
  end

  def save_data_last_access_time(file_name, room_index) #TODO:FIXME これと下記のtimesメソッドは委譲関係が逆
    save_data_last_access_times([file_name], (room_index .. room_index))
  end

  def save_data_last_access_times(file_names, target_range) #TODO:FIXME 委譲関係が逆.単体分の処理をtimeメソッドに委譲する方が自然
    logging(file_names, "getSaveDataLastAccessTimes fileNames")

    save_dirs = save_data_dirs(target_range)
    logging(save_dirs, "getSaveDataLastAccessTimes saveDirs")

    result = {}
    save_dirs.each do |saveDir|
      next unless (/data_(\d+)\Z/ === saveDir)

      room_index = $1.to_i
      next unless (target_range.include?(room_index))

      save_files         = names_exist_file(saveDir, file_names)
      m_times            = save_files.collect { |i| File.mtime(i) }
      result[room_index] = m_times.max
    end

    logging(result, "getSaveDataLastAccessTimes result")

    result
  end

  def set_dir_index(index)
    @dir_index = index.to_i
  end

  def save_data_dir_index

    return @dir_index if @dir_index

    logging(@requestData.inspect, "requestData")
    logging(@dir_index_obj, "saveDataDirIndexObject")

    if @dir_index_obj.instance_of?(StringIO)
      logging "is StringIO"
      @dir_index_obj = @dir_index_obj.string
    end
    data_dir_index = @dir_index_obj.to_i

    logging(data_dir_index.inspect, "saveDataDirIndex")

    unless @sample_mode
      if data_dir_index > @max_number
        raise "saveDataDirIndex:#{data_dir_index} is over Limit:(#@max_number)"
      end
    end

    logging(data_dir_index, "saveDataDirIndex")

    data_dir_index
  end

  def dir_name
    logging("getDirName begin..")
    dir_name_by_index(save_data_dir_index)
  end

  def dir_name_by_index(dir_index)
    dir_base_path = save_date_dir_base_path

    save_data_dir_name = ''
    if dir_index >= 0
      dir_name           = "data_" + dir_index.to_s
      save_data_dir_name = File.join(dir_base_path, dir_name)
      logging(save_data_dir_name, "saveDataDirName created")
    end

    save_data_dir_name
  end

  def create_dir
    logging('createDir begin')
    logging(dir_name, 'createDir saveDataDirName')

    if FileTest.directory?(dir_name)
      raise "このプレイルームはすでに作成済みです。"
    end

    logging("cp_r new save data...")

    Dir::mkdir(dir_name)
    File.chmod(0777, dir_name)

    options = {
        :preserve => true,
    }

    source_dir = 'saveData_forNewCreation'

    file_names = all_save_file_names
    src_files  = names_exist_file(source_dir, file_names)

    FileUtils.cp_r(src_files, dir_name, options)
    logging("cp_r new save data")
    logging('createDir end')
  end

  def all_save_file_names
    file_names = []

    save_files = $saveFiles.values + [
        $loginUserInfo,
        $playRoomInfo,
        $chatMessageDataLogAll,
    ]

    save_files.each do |i|
      file_names << i
      file_names << i + ".lock"
    end

    file_names
  end

  def remove_dir(save_data_dir_index)
    dir_name = dir_name_by_index(save_data_dir_index)
    SaveDirInfo::remove_dir(dir_name)
  end

  def self.remove_dir(dir_name)
    return unless (FileTest.directory?(dir_name))

    # force = true
    # FileUtils.remove_entry_secure(dirName, force)
    # 上記のメソッドは一部レンタルサーバ(さくらインターネット等）で禁止されているので、
    # この下の方法で対応しています。

    files = Dir.glob(File.join(dir_name, "*"))

    logging(files, "removeDir files")
    files.each do |fileName|
      File.delete(fileName.untaint)
    end

    Dir.delete(dir_name)
  end

  def real_save_file_name(file_name)
    begin
      logging(dir_name, "saveDataDirName")

      return File.join(dir_name, file_name)
    rescue => e
      loggingForce($!.inspect)
      loggingForce(e.inspect)
      raise e
    end
  end

end
