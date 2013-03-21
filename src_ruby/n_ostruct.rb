# encoding:utf-8
require 'ostruct'
require_relative 'nested_hash'

class NestedOpenStruct < OpenStruct
  include Enumerable

  # コンストラクタ.
  # @param [Hash] base_hash 設定する要素とその値になるHashオブジェクト
  def initialize(base_hash = nil)
    @table = {}
    if base_hash
      base_hash.each do |key, value|
        @table[:"#{key}"] = value.instance_of?(Hash) ? NestedOpenStruct.new(value) : value
        new_ostruct_member(key)
      end
    end
  end

  # 自身に設定されている要素とその値をHashオブジェクトに変換して返します.
  # 値にNestedOpenStructインスタンスが含まれている場合は、再帰的にHashオブジェクトに変換されます
  def marshal_dump
    result = @table.dup
    result.each do |key, value|
      result[key] = value.instance_of?(NestedOpenStruct) ? value.marshal_dump : value
    end
  end

  # 引数xのHashを元に@tableを再構築します.
  # 事実上、インスタンスを再生成する事を意味します
  def marshal_load(x)
    @table = {}
    x.each do |key,value|
      @table[:"#{key}"] = value.instance_of? Hash ? NestedOpenStruct.new(value) : value
      new_ostruct_member(key)
    end
  end

  # add_objを再帰的にmergeします. add_objがHashまたはNestedOpenStructでない場合は何もしません
  def merge!(add_obj, nil_clear = false)
    case add_obj
      when Hash
        @table = self.marshal_dump.deep_merge!(NestedOpenStruct.new(add_obj).marshal_dump, nil_clear)
      when NestedOpenStruct
        @table = self.marshal_dump.deep_merge!(add_obj.marshal_dump, nil_clear)
      else
        # nothing
    end

    self
  end

  # @tableのeach処理を実施します
  def each
    @table.each{|key ,value| yield(key, value)}
  end

  # オブジェクト比較演算子のオーバーロード.
  # otherがNestedOpenStructであり、otherのtableが自身の@tableと等価である時に真と見なします
  def ==(other)
    return false unless(other.kind_of?(NestedOpenStruct))
    return @table == other.table
  end
end

# テストハーネス
if $0 === __FILE__
  test = {key1: 'one', key2: [1,2,3,4,5], key3: {n_key1: 'nested_value'}, 'key5' => 'val'}
  n_ostruct = NestedOpenStruct.new(test)
  puts "instance: #{n_ostruct}"
  puts "key1: #{n_ostruct.key1}"
  puts "key2: #{n_ostruct.key2}"
  puts "key3: #{n_ostruct.key3}"
  puts "undefine: #{n_ostruct.key4}:#{n_ostruct.key4.class}"
  puts "n_key1: #{n_ostruct.key3.n_key1}"
  puts "inspect: #{n_ostruct.inspect}"
  puts "to_hash: #{n_ostruct.marshal_dump}"
  puts "merge!(in Hash): #{n_ostruct.merge!({"add_key1" => "add!"}).marshal_dump}"
  add_n_ostruct = NestedOpenStruct.new({"key3" => {n_key2: 'add_nested_value'}})
  puts "merge!(in NestedOpenStruct): #{n_ostruct.merge!(add_n_ostruct).marshal_dump}"
  puts "merge!(in illegal instance): #{n_ostruct.merge!('other').marshal_dump}"
  puts "map: #{n_ostruct.map{|_,v| p "#{v}" }}"
end