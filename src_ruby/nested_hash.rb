#encoding: utf-8

class Hash
=begin
Hash.mergeをネストされた多重Hashに対応させたメソッド.
同一Keyの要素がHash同士である場合はHash.mergeによってマージします.
nil_clearがtrueの場合はtarget内のnil要素は全てnilで上書きされます.
=end
  def deep_merge(target, nil_clear = false)
    raise ArgumentError('Not Hash') unless target.kind_of?(Hash)
    result = self.clone
    result.merge(target) do |key, self_val, tar_val|
      self_val =
          if tar_val.kind_of?(Hash)
            self_val = {} if self_val.nil? || !self_val.kind_of?(Hash)
            self_val.deep_merge(tar_val, nil_clear)
          elsif tar_val.nil?
            nil_clear ? tar_val : self_val
          else
            tar_val
          end
    end
  end

=begin
Hash.deep_mergeの破壊的メソッドです.
=end
  def deep_merge!(target, nil_clear = false)
    raise ArgumentError('Not Hash') unless target.kind_of?(Hash)
    merge!(target) do |key, self_val, tar_val|
      self_val =
          if tar_val.kind_of?(Hash)
            self_val = {} if self_val.nil? || !self_val.kind_of?(Hash)
            self_val.deep_merge!(tar_val, nil_clear)
          elsif tar_val.nil?
            nil_clear ? tar_val : self_val
          else
            tar_val
          end
    end
  end
end

if __FILE__ == $0
# 1.sourceとtargetのマージ
  source = { 'a' => 'value1', 'b' => { 'c' => 'value2', 'd' => { 'e' => 'value3' } } }
  target = { 'w' => 'value4', 'b' => { 'x' => 'value5', 'y' => { 'z' => 'value6' } } }
  source = source.deep_merge(target)
  p source
# 2.sourceの特定箇所のみをマージ
  target = { 'b' => { 'x' => 'update!' } }
  source = source.deep_merge(target)
  p source
# 3.sourceの要素をnilでクリア
  target = { 'b' => { 'c' => nil } }
  source = source.deep_merge(target, true)
  p source
# 4.nil_flgがfalseの場合はnilでクリアされない
  target = { 'b' => { 'd' => { 'e' => nil } } }
  source = source.deep_merge(target)
  p source
end