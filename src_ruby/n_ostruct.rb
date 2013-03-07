# encoding:utf-8
require 'ostruct'
require './nested_hash'

class NestedOpenStruct < OpenStruct

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
  def to_hash
    result = @table.dup
    result.each do |key, value|
      result[key] = value.instance_of?(NestedOpenStruct) ? value.to_hash : value
    end
  end

  # add_objを再帰的にmergeします. add_objがHashまたはNestedOpenStructでない場合は何もしません
  def merge!(add_obj, nil_clear = false)
    case add_obj
      when Hash
        @table = self.to_hash.deep_merge!(NestedOpenStruct.new(add_obj).to_hash, nil_clear)
      when NestedOpenStruct
        @table = self.to_hash.deep_merge!(add_obj.to_hash, nil_clear)
      else
        # nothing
    end

    self
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
  puts "to_hash: #{n_ostruct.to_hash}"
  puts "merge!(in Hash): #{n_ostruct.merge!({"add_key1" => "add!"}).to_hash}"
  add_n_ostruct = NestedOpenStruct.new({"key3" => {n_key2: 'add_nested_value'}})
  puts "merge!(in NestedOpenStruct): #{n_ostruct.merge!(add_n_ostruct).to_hash}"
  puts "merge!(in illegal instance): #{n_ostruct.merge!('other').to_hash}"
end