# encoding:utf-8

require 'yaml'
require './n_ostruct'

class Configure
  DEFAULT_FILE_PATH = 'settings.yml'
  @@base ||= NestedOpenStruct.new(YAML.load_file(DEFAULT_FILE_PATH))

  def self.method_missing(method, *args)
    @@base.send(method, *args)
  end
end

if $0 === __FILE__
  puts "version: #{Configure.Version.numbering}"
  puts "undefined: #{Configure.undefined}"
end