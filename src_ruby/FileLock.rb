
class FileLock
  
  def initialize(file_name)
    @file_name = file_name

    create unless File.exist?(@file_name)
  end
  
  def create
    File.open(@file_name, 'w+'){|file| file.write('lock') }
  end
  
  def in_action(&action)
    open(@file_name, 'r+') do |f|
      f.flock(File::LOCK_EX)
      begin
        action.call
      ensure
        f.flush()
        f.flock(File::LOCK_UN)
      end
    end
  end
  
end
