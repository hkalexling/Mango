require "./spec_helper"

describe "compare_numerically" do
  it "sorts filenames with leading zeros correctly" do
    ary = ["010.jpg", "001.jpg", "002.png"]
    ary.sort! { |a, b|
      compare_numerically a, b
    }
    ary.should eq ["001.jpg", "002.png", "010.jpg"]
  end

  it "sorts filenames without leading zeros correctly" do
    ary = ["10.jpg", "1.jpg", "0.png", "0100.jpg"]
    ary.sort! { |a, b|
      compare_numerically a, b
    }
    ary.should eq ["0.png", "1.jpg", "10.jpg", "0100.jpg"]
  end

  # https://ux.stackexchange.com/a/95441
  it "sorts like the stack exchange post" do
    ary = ["2", "12", "200000", "1000000", "a", "a12", "b2", "text2",
           "text2a", "text2a2", "text2a12", "text2ab", "text12", "text12a"]
    ary.reverse.sort! { |a, b|
      compare_numerically a, b
    }.should eq ary
  end

  # https://github.com/hkalexling/Mango/issues/22
  it "handles numbers larger than Int32" do
    ary = ["14410155591588.jpg", "21410155591588.png", "104410155591588.jpg"]
    ary.reverse.sort! { |a, b|
      compare_numerically a, b
    }.should eq ary
  end
end

describe "is_supported_file" do
  it "returns true when the filename has a supported extension" do
    filename = "manga.cbz"
    is_supported_file(filename).should eq true
  end

  it "returns true when the filename does not have a supported extension" do
    filename = "info.json"
    is_supported_file(filename).should eq false
  end

  it "is case insensitive" do
    filename = "manga.ZiP"
    is_supported_file(filename).should eq true
  end
end

describe "chapter_sort" do
  it "sorts correctly" do
    ary = ["Vol.1 Ch.01", "Vol.1 Ch.02", "Vol.2 Ch. 2.5", "Ch. 3", "Ch.04"]
    sorter = ChapterSorter.new ary
    ary.reverse.sort! do |a, b|
      sorter.compare a, b
    end.should eq ary
  end
end
