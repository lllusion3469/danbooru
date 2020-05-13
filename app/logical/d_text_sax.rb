class DTextSax < Nokogiri::XML::SAX::Document
  MAP = {
    "small" => "tn",
    "sub" => "tn",
    "b" => "b",
    "strong" => "b",
    "i" => "i",
    "em" => "i",
    "u" => "u",
    "s" => "s",
    "strike" => "s",
  }

  attr_reader :dtext

  def initialize
    @dtext = ""
    @url = nil
  end

  def start_element(name, attrs = [])
    if (a = MAP[name])
      @dtext << "[#{a}]"
      return
    end

    case name
    when "br"
      @dtext << "\n"
    when "blockquote"
      @dtext << "[quote]"
    when "li"
      "* "
    when "a"
      url = attrs.to_h["href"]
      if url.present?
        @url = url
        @dtext << '"'
      end
    when "img"
      attrs = attrs.to_h
      alt_text = attrs["title"] || attrs["alt"] || ""
      src = attrs["src"]

      if @url
        @dtext << alt_text
      elsif alt_text.present? && src.present?
        @dtext << %("#{alt_text}":[#{src}]\n\n)
      end
    when "h1", "h2", "h3", "h4", "h5", "h6"
      @dtext << "#{name}. "
    end
  end

  def end_element(name)
    if (a = MAP[name])
      @dtext << "[/#{a}]"
      return
    end

    case name
    when "p", "ul", "ol"
      @dtext << "\n\n"
    when "blockquote"
      @dtext << "[/quote]\n\n"
    when "li"
      @dtext << "\n"
    when "h1", "h2", "h3", "h4", "h5", "h6"
      @dtext << "\n\n"
    when "a"
      if @url
        @dtext << %(":[#{@url}])
        @url = nil
      end
    end
  end

  def characters(s)
    @dtext << s.gsub(/(?:\r|\n)+$/, "")
  end
end
