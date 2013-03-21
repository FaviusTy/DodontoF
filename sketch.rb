# encoding:utf-8

class TestClass
  include Enumerable

  def self.arr
    @arr ||= [0,1,2,3]
  end

  def self.each
    arr.each{ |i| yield(i) }
  end
end

TestClass.collect{|i| i < 2}.each{|i| puts i }


