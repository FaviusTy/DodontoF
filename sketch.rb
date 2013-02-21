# encoding:utf-8

def test
  nil
end

def arr
  return [0,1,2]
end

def doc
  ret_str = <<-EOS
test
message
  EOS
end

var = test || false
puts :"#{var}"
puts arr[1]
puts %Q!"String is #{var}"!
puts doc

