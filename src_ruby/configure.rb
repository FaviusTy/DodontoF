# encoding:utf-8
require 'yaml'
require_relative 'n_ostruct'

# Applicationの共通設定項目をymlファイルから生成したNestedOpenStruct経由でアクセス可能にする
class Configure
  DEFAULT_FILE_PATH = 'settings.yml'

  def self.base
    @base ||= NestedOpenStruct.new(YAML.load_file(DEFAULT_FILE_PATH))
  end

  def self.method_missing(method, *args)
    base.send(method, *args)
  end

  def self.version
    "#{version_only}(#{version_date})"
  end

  #ログアウトと判定される応答途絶時間(秒)
  #下記秒数以上ブラウザから応答が無い場合はログアウトしたと判定。
  def self.login_timeout
    refresh_timeout * 1.5 + 10
  end

  # ログイン状況を記録するファイル
  # TODO:FIXME これはsaveDirInfoに定義すべき
  def self.login_count_file
    File.join(save_data_dir, 'saveData', 'loginCount.txt')
  end
end

# テストハーネス
if $0 === __FILE__
  puts "version: #{Configure.version}"
  puts "refresh_timeout: #{Configure.refresh_timeout}:#{Configure.refresh_timeout.class}"
  puts "login_timeout: #{Configure.login_timeout}:#{Configure.login_timeout.class}"
  puts "login_count_file: #{Configure.login_count_file}"
  puts "save_data_lock_file_dir: #{Configure.save_data_lock_file_dir}:#{Configure.save_data_lock_file_dir.class}"
  puts "dicebot_order: #{Configure.dicebot_order}"
  puts "undefined: #{Configure.undefined}"
end