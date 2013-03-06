# encoding: utf-8

require 'fileutils'


class SaveDirInfo

  attr_reader :max_number

  # ディレクトリ名の共通プリフィクス
  PREFIX_DIR_NAME = 'data_'

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
  def root_dir_path
    File.join(@sub_dir, 'saveData')
  end

  def each_with_index(target_range, *file_names)
    dirs = exist_data_dirs(target_range)

    dirs.each_with_index do |directory, _|
      next unless (/#{PREFIX_DIR_NAME}(\d+)\Z/ === directory)

      room_index = $1.to_i
      save_files  = names_exist_file(directory, file_names)

      yield(save_files, room_index)
    end
  end

  # file_namesのうち、引数dir内に存在するファイルのファイル名のみをフィルタリングして返す
  def names_exist_file(dir, file_names)
    file_names.map {|file_name| File.join(dir, file_name) }
              .find_all {|file| FileTest.exist? file }
  end

  # target_range範囲内のindexのうち、ディレクトリが存在するものを返す
  def exist_data_dirs(target_range)
    dir_names = target_range.map{|i| "data_#{i}" }
    names_exist_file(root_dir_path, dir_names) #TODO:FIXME ディレクトリ抽出にfileとあるメソッド名を使うのはちょっと微妙
  end

  # target_rangeの範囲内のdataディレクトリ別にfile_namesにあるファイル中で最新のtimestampを配列にして返す
  def save_data_last_access_times(file_names, target_range) #TODO:FIXME 委譲関係が逆.単体分の処理をtimeメソッドに委譲する方が自然
    logging(file_names, 'getSaveDataLastAccessTimes fileNames')

    data_dirs = exist_data_dirs(target_range)
    logging(data_dirs, 'getSaveDataLastAccessTimes saveDirs')

    result = {}
    data_dirs.each do |saveDir|
      next unless (/#{PREFIX_DIR_NAME}(\d+)\Z/ === saveDir)

      room_index = $1.to_i
      next unless (target_range.include?(room_index))

      save_files         = names_exist_file(saveDir, file_names)
      m_times            = save_files.collect { |i| File.mtime(i) }
      result[room_index] = m_times.max
    end

    logging(result, 'getSaveDataLastAccessTimes result')

    result
  end

  def set_dir_index(index)
    @dir_index = index.to_i
  end

  def save_data_dir_index
    return @dir_index if @dir_index

    logging(@dir_index_obj, 'saveDataDirIndexObject')

    if @dir_index_obj.instance_of?(StringIO)
      logging 'is StringIO'
      @dir_index_obj = @dir_index_obj.string
    end
    dir_index = @dir_index_obj.to_i

    logging(dir_index.inspect, 'saveDataDirIndex')

    unless @sample_mode
      if dir_index > @max_number
        raise "saveDataDirIndex:#{dir_index} is over Limit:(#{@max_number})"
      end
    end

    logging(dir_index, 'saveDataDirIndex')

    dir_index
  end

  def data_dir_path
    logging 'getDirName begin..'
    dir_name_by_index(save_data_dir_index)
  end

  def dir_name_by_index(dir_index)
    save_data_dir_name = ''

    if dir_index >= 0
      dir_name           = 'data_' + dir_index.to_s
      save_data_dir_name = File.join(root_dir_path, dir_name)
      logging(save_data_dir_name, 'saveDataDirName created')
    end

    save_data_dir_name
  end

  def create_dir
    logging('createDir begin')
    logging(data_dir_path, 'createDir saveDataDirName')

    if FileTest.directory?(data_dir_path)
      raise 'このプレイルームはすでに作成済みです。'
    end

    logging 'cp_r new save data...'

    Dir::mkdir(data_dir_path)
    File.chmod(0777, data_dir_path)

    options = {
        :preserve => true,
    }

    source_dir = 'saveData_forNewCreation'

    file_names = all_save_file_names
    src_files  = names_exist_file(source_dir, file_names)

    FileUtils.cp_r(src_files, data_dir_path, options)
    logging 'cp_r new save data'
    logging 'createDir end'
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
      file_names << i + '.lock'
    end

    file_names
  end

  def remove_dir(save_data_dir_index)
    dir_name = dir_name_by_index(save_data_dir_index)
    SaveDirInfo::remove_dir(dir_name)
  end

  # TODO:FIXME dir_nameは実際にはフルパスであることを要求しているが、内部的に求められるはずなのでそのように改修する
  def self.remove_dir(dir_name)
    return unless (FileTest.directory?(dir_name))

    # force = true
    # FileUtils.remove_entry_secure(dirName, force)

    # 上記のメソッドは一部レンタルサーバ(さくらインターネット等）で禁止されているので、
    # この下の方法で対応しています。

    files = Dir.glob(File.join(dir_name, '*'))

    logging(files, 'removeDir files')
    files.each do |fileName|
      File.delete(fileName.untaint)
    end

    Dir.delete(dir_name)
  end

  # TODO:WAHT? このメソッドではfile_nameをフルパスに整形する際にそれが実在することを保証できていない
  # 用途を勘違いしてる？
  def real_save_file_name(file_name)
    begin
      logging(data_dir_path, 'saveDataDirName')

      return File.join(data_dir_path, file_name)
    rescue => e
      loggingForce($!.inspect)
      loggingForce(e.inspect)
      raise e
    end
  end

end

# テストハーネス
if $0 === __FILE__
  require './loggingFunction'
  require 'stringio'
  # カレントディレクトリをDodontoFServer.rbの位置に変更
  Dir.chdir('../')


  save_data = SaveDirInfo.new
  puts "saveData initialized : #{save_data}"
  save_data.init(0)
  puts 'init called'
  puts "root_dir_path : #{save_data.root_dir_path}"
  puts "exist_data_dirs : #{save_data.exist_data_dirs((0 .. 0))}"
  puts "data_dir_path : #{save_data.data_dir_path}"
  puts "real_save_file_name : #{save_data.real_save_file_name('.')}"
end