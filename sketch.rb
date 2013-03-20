# encoding:utf-8

module TEST
  def self.test_a
    puts "test_a"
  end
end

TEST.send(:test_a)


