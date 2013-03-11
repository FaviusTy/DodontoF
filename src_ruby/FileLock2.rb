
class FileLock2
  
  def initialize(lockFileName, isReadOnly = false)
    @file_name = lockFileName
    @isReadOnly = isReadOnly
    
    unless( File.exist?(@file_name) )
      createLockFile
    end
  end
  
  def createLockFile
    File.open(@file_name, "w+") do |file|
      file.write("lock")
    end
  end
  
  def lock(&action)
    mode = (@isReadOnly ? File::LOCK_SH : File::LOCK_EX)
    open(@file_name, "r+") do |f|
      f.flock(mode)
      begin
        action.call
      ensure
        f.flush() unless( @isReadOnly )
        f.flock(File::LOCK_UN)
      end
    end
  end
  
end
