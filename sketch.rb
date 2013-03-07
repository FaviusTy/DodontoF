# encoding:utf-8
require 'stringio'

io = StringIO.new('','r')
puts [1,2,3,4,5,6].find_all {|v| (v % 2) == 0  }
puts (1 .. 10).find_all{|i| (i % 2) == 0}


