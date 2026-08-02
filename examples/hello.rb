#lang (creme syntax ruby)
def greet(name)
  if name
    puts "Hello, #{name}!"
  else
    puts "Hello, stranger"
  end
end

greet("World")
greet(nil)

[1, 2, 3].each do |n|
  puts n * 2
end
