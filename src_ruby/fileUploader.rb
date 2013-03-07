# encoding: utf-8

require 'kconv'
require 'config'

class FileUploader
  
  def initialize
    @result_message = '....'
  end
  
  def init(upload_file_info, max_file_size, max_file_count)
    @upload_file_info = upload_file_info
    @max_file_size = max_file_size
    @max_file_count = max_file_count
  end
  
  def upload_file_name
    upload_file_name = @upload_file_info.original_filename
    logging(upload_file_name, 'uploadFileName')

    upload_file_name
  end
  
  def upload_file_extension
    File.extname(upload_file_name)
  end
  
  def validation_file_size
    file_size = @upload_file_info.size
    logging(file_size, 'fileSize')
    if file_size > (@max_file_size * 1024 * 1024)
      raise "ファイルのサイズが上限の#{ sprintf('%0.2f', @max_file_size) }MBを超えています。（アップロードしようとしたファイルのサイズ:#{ sprintf('%0.2f', 1.0 * file_size / 1024 / 1024) }MB)"
    end
  end
  
  def recreate_dir(dir_name)
    unless FileTest.directory?(dir_name)
      Dir::mkdir(dir_name)
    end
    
    files = Dir.glob( File.join(dir_name, '*') )
    logging(files, 'dir include fileNames')
    
    new_order_files = files.sort!{|a, b| File.mtime(b) <=> File.mtime(a)}
    new_order_files.each_with_index do |file, index|
      if index < (@max_file_count - 1)
        logging('@fileCountLimit', @max_file_count)
        logging('delete pass file', file)
        next
      end
      File.delete(file)
      logging('deleted file', file)
    end
  end
  
  def create_upload_file(save_data_index, file_name, sub_dir_name = '.')
    
    save_dir_info = SaveData.new(save_data_index, $saveDataMaxCount, $SAVE_DATA_DIR)
    save_dir_name = save_dir_info.real_save_file_name(sub_dir_name)
    logging(save_dir_name, 'saveDirName')
    
    unless sub_dir_name == '.'
      recreate_dir(save_dir_name)
    end
    
    save_file_name = File.join(save_dir_name, file_name)
    logging(save_file_name, 'saveFileName')
    
    logging('open...')
    open(save_file_name, 'w+') do |file|
      
      file.binmode
      file.write(@upload_file_info.read)
    end
    logging('close...')
    
    logging('createUploadFile end.')

    save_file_name
  end
  
  def set_success_meesage(result) #TODO:WHAT? まるで意味のないメソッドに見える。。。
    @result_message = 'アップロードに成功しました。<br />この画面を閉じてください。'
  end
  
  def set_error_message(result) #TODO:FIXME 上記のSuccessもそうだが、常にこれらを使い分けて呼び出す必要があるならそもそも@result_messageは要らない？
    @result_message = "result:#{result}\nアップロードに失敗しているような気がします。<br />・・・が、もしかすると仕様変更かもしれません。"
  end
  
  def set_exception_error_message(exception) #TODO:FIXME 同上
    logging 'Exception'
    
    $debug = true
    
    @result_message = 'アップロード中に下記のエラーが発生しました。もう一度試すか管理者に連絡してください。<br />'
    @result_message += '<hr /><br />'
    @result_message += exception.to_s + '<br />'
    @result_message += exception.inspect.toutf8
    @result_message += $!.inspect.toutf8
    @result_message += $@.inspect.toutf8
    logging(@result_message)
  end
  
  def print_result_html
    header = "Content-Type: text/html\ncharset: utf-8\n\n"
    print header
    
    message = '<html>
<META HTTP-EQUIV="Content-type" CONTENT="text/html; charset=UTF-8">
<body>
' + @result_message + '
</body></html>'
    message = message.toutf8
    
    logging(message)
    
    print message.toutf8
  end
end


