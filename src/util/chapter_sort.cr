# Helper method used to sort chapters in a folder
# It respects the keywords like "Vol." and "Ch." in the filenames
# This sorting method was initially implemented in JS and done in the frontend.
#   see https://github.com/hkalexling/Mango/blob/
#     07100121ef15260b5a8e8da0e5948c993df574c5/public/js/sort-items.js#L15-L87

require "big"

private class Item
  getter numbers : Hash(String, BigDecimal)

  def initialize(@numbers)
  end

  # Compare with another Item using keys
  def <=>(other : Item, keys : Array(String))
    keys.each do |key|
      if !@numbers.has_key?(key) && !other.numbers.has_key?(key)
        next
      elsif !@numbers.has_key? key
        return 1
      elsif !other.numbers.has_key? key
        return -1
      elsif @numbers[key] == other.numbers[key]
        next
      else
        return @numbers[key] <=> other.numbers[key]
      end
    end

    0
  end
end

private class KeyRange
  getter min : BigDecimal, max : BigDecimal, count : Int32

  def initialize(value : BigDecimal)
    @min = @max = value
    @count = 1
  end

  def update(value : BigDecimal)
    @min = value if value < @min
    @max = value if value > @max
    @count += 1
  end

  def range
    @max - @min
  end
end

class ChapterSorter
  @sorted_keys = [] of String

  def initialize(str_ary : Array(String))
    keys = {} of String => KeyRange

    str_ary.each do |str|
      scan str do |k, v|
        if keys.has_key? k
          keys[k].update v
        else
          keys[k] = KeyRange.new v
        end
      end
    end

    # Get the array of keys string and sort them
    @sorted_keys = keys.keys
      # Only use keys that are present in over half of the strings
      .select do |key|
        keys[key].count >= str_ary.size / 2
      end
      .sort! do |a_key, b_key|
        a = keys[a_key]
        b = keys[b_key]
        # Sort keys by the number of times they appear
        count_compare = b.count <=> a.count
        if count_compare == 0
          # Then sort by value range
          b.range <=> a.range
        else
          count_compare
        end
      end
  end

  def compare(a : String, b : String)
    item_a = str_to_item a
    item_b = str_to_item b
    item_a.<=>(item_b, @sorted_keys)
  end

  private def scan(str, &)
    str.scan /([^0-9\n\r\ ]*)[ ]*([0-9]*\.*[0-9]+)/ do |match|
      key = match[1]
      num = match[2].to_big_d

      yield key, num
    end
  end

  private def str_to_item(str)
    numbers = {} of String => BigDecimal
    scan str do |k, v|
      numbers[k] = v
    end
    Item.new numbers
  end
end
