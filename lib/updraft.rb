# =============================================================================
# updraft.rb: Umpteenth Portable Document Renderer And Formatting Tool
#
# Author: Steve Shreeve <steve.shreeve@gmail.com>
#   Date: March 9, 2010
#  Legal: Same license as Ruby.
#  Props: Many ideas from FPDF.php and FPDF.rb
# =============================================================================
# TODO:
# * font - only emit when necessary (refer to how colors are handled)
# * disable auto-page break (in print() method)
# * wrap - turn wrapping on/off
# * feed - auto linefeed on/off
# =============================================================================

require 'date'
require 'enumerator'
require 'zlib'

class Updraft
  attr_accessor :author, :creator, :keywords, :subject, :title

  # ==[ Document ]=============================================================

  def initialize(*args, &block)
    @buffer     = ''
    @offsets    = []
    @pages      = []
    @flip       = {}
    @font       = {}
    @fonts      = {}
    @images     = {}
    @colors     = {}
    @page       = 0

    # defaults
    @compress      = false                  # compression
    @orientation   = 'P'                    # portrait
    @scale         = 72.0                   # in
    @format        = [612, 792]             # letter
    @spacing       = 1.0                    # line spacing
    @thick         = 1.0                    # line thickness
    @dpi           = 300.0                  # for images
    @tab           = 18.0                   # for indenting
    @zoom          = 'fullwidth'            # page width
    @layout        = 'continuous'           # one page
    @path          = File.dirname(__FILE__) # font path
    name,type,size = 'helvetica', '', 12    # font
    @margins       = {
      'top'    => 36.0,
      'right'  => 36.0,
      'bottom' => 36.0,
      'left'   => 36.0,
      'cell'   => 1.5,
    }

    # process arguments
    args.each do |old|
      case arg = old.is_a?(String) ? old.downcase : old

      # orientation
      when 'portrait', 'p', 'landscape', 'l' then @orientation = arg[0,1].upcase

      # scale
      when 'pt' then @scale =  1.0
      when 'mm' then @scale = 72.0 / 25.4
      when 'cm' then @scale = 72.0 / 2.54
      when 'in' then @scale = 72.0

      # format
      when 'a3'     then @format = [841.89, 1190.55]
      when 'a4'     then @format = [595.28,  841.89]
      when 'a5'     then @format = [420.94,  595.28]
      when 'letter' then @format = [612   ,  792   ]
      when 'legal'  then @format = [612   , 1008   ]

      # display
      when 'fullpage', 'fullwidth', 'real' then @zoom   = arg
      when 'single', 'continuous', 'two'   then @layout = arg

      # font
      when /[\/\\]/   then @path = old
      when Numeric    then size = arg
      when /^[biu]*$/ then type = arg
      when String     then name = old

      # compression
      when true,false then @compress = arg

      # hashes
      when Hash
        arg.each do |key,val|
          case key = key.to_s.downcase
          when 'top','right','bottom','left','cell' then @margins[key] = val.to_f * @scale
          when 'spacing' then @spacing = val.to_f
          when 'thick'   then @thick   = val.to_f * @scale
          when 'dpi'     then @dpi     = val.to_f
          when 'margins' then margins(val)
          when 'colors'  then colors(*val)
          else raise "invalid hash key #{key.inspect}"
          end
        end

      # syntactic sugar (may require @scale to be defined)
      when Array
        case arg.size
        when 1 then @tab = arg[0].to_f * @scale # tab size for indent
        when 2 then @format = [arg[0] * @scale, arg[1] * @scale]
        end

      else raise "invalid arg #{arg.inspect}"
      end
    end

    # computed values
    font(name, type, size)
    @wide, @tall = *(@orientation == 'P' ? @format : @format.reverse)
    @x = @margins['left']
    @y = @margins['top']
    @indents = [@x]

    # invoke optional code block
    instance_eval(&block) if block_given?
  end

  def finish
    @state = 1 # in-document
    out_header
    out_info
    out_catalog
    out_pages
    out_fonts
    out_images
    out_resources
    out_xrefs
    out_trailer
    @state = 3 # finished
  end

  def save(path)
    finish unless @state == 3 # finished
    File.open(path, 'wb') {|f| f.puts(@buffer)}
    path
  end

  def to_s
    @buffer
  end

  # ==[ Output ]===============================================================

  def out(str)
    if @state == 2 # in-page
      @pages[@page] << "#{str}\n"
    else
      @buffer << "#{str}\n"
    end
  end

  def out_stream(str)
    out("stream")
    out(str)
    out("endstream")
  end

  def out_line_color(color)
    tag = color[' '] ? "RG" : "G"
    out("#{color} #{tag}")
  end

  def out_fill_color(color)
    tag = color[' '] ? "rg" : "g"
    out("#{color} #{tag}")
  end

  def out_rect(x, y, w, h, type='d') # d=draw, f=fill, df=both
    type = case type.downcase
      when 'f'        then 'f'
      when 'df', 'fd' then 'B'
      else                 'S'
    end
    out("%.3f %.3f %.3f %.3f re %s" % [x, y, w, h, type])
  end

  def out_line(x1, y1, x2, y2)
    out("%.3f %.3f m %.3f %.3f l S" % [x1, y1, x2, y2])
  end

  def out_text(x, y, str)
    out("BT %.3f %.3f Td (%s) Tj ET" % [x, y, str])
  end

  def out_font(i, size)
    out("BT /F%d %.3f Tf ET" % [i, size]) if @state == 2 # in-page
  end

  def out_image(w, h, x, y, i)
    out("q %.3f 0 0 %.3f %.3f %.3f cm /I%d Do Q" % [w, h, x, y, i])
  end

  # ==[ Objects ]==============================================================

  def new_obj
    @offsets << @buffer.length
    out("#{@offsets.size} 0 obj")
    @offsets.size
  end

  def end_obj
    out("endobj")
  end

  def out_header
    out("%PDF-1.3")
  end

  def out_info
    new_obj # 1
    out("<<")
    out("/Producer "     << string('Ruby Updraft 1.0'))
    out("/Title "        << string(@title   )) if @title
    out("/Subject "      << string(@subject )) if @subject
    out("/Author "       << string(@author  )) if @author
    out("/Keywords "     << string(@keywords)) if @keywords
    out("/Creator "      << string(@creator )) if @creator
    out("/CreationDate " << string("D: " + DateTime.now.to_s))
    out(">>")
    end_obj
  end

  def out_catalog
    new_obj # 2
    out("<<")
    out("/Type /Catalog")
    out("/Pages 3 0 R")
    case @zoom
      when "fullpage"   then out("/OpenAction [4 0 R /Fit]")
      when "fullwidth"  then out("/OpenAction [4 0 R /FitH null]")
      when "real"       then out("/OpenAction [4 0 R /XYZ null null 1]")
      when Numeric      then out("/OpenAction [4 0 R /XYZ null null #{@zoom/100}]")
    end
    case @layout
      when "single"     then out("/PageLayout /SinglePage")
      when "continuous" then out("/PageLayout /OneColumn")
      when "two"        then out("/PageLayout /TwoColumnLeft")
    end
    out(">>")
    end_obj
  end

  def out_pages
    new_obj # 3
    out("<<")
    out("/Type /Pages")
    out("/Kids [")
    out((1..@page).map {|page| "#{2 + 2 * page} 0 R"}.join("\n"))
    out("]")
    out("/Count #{@page}")
    ref = 4 + @page * 2 # initial offset
    @fonts.each  {|k,v| ref += @core_fonts[k] ? 1 : 4} # with fonts
    @images.each {|k,v| ref += v['pal']       ? 2 : 1} # with images
    out("/Resources #{ref} 0 R")
    out("/MediaBox [0 0 %.2f %.2f]" % [@wide, @tall])
    out(">>")
    end_obj

    1.upto(@page) do |page|
      new_obj # 4, steps by 2
      out("<<")
      out("/Type /Page")
      out("/Parent 3 0 R")
      out("/MediaBox [0 0 %.2f %.2f]" % [@tall, @wide]) if @flip[page]
      out("/Contents #{3 + page * 2} 0 R")
      #!# handle annotations (links)...
      out(">>")
      end_obj

      data = @pages[page].chomp
      data = Zlib::Deflate.deflate(data) if @compress

      new_obj
      out("<<")
      out("/Filter /FlateDecode") if @compress
      out("/Length #{data.length}")
      out(">>")
      out_stream(data)
      end_obj
    end
  end

  def out_fonts
    @fonts.values.sort{|a,b| a['i'] <=> b['i']}.each do |font|
      font['type'] =~ /^Type1|TrueType$/ or raise "invalid font type #{font['type']}"

      # font
      font['n'] = ref = new_obj
      out("<<")
      out("/Type /Font")
      out("/BaseFont /#{font['name']}")
      out("/Subtype /#{font['type']}")
      out("/Encoding /WinAnsiEncoding") if font['font'] !~ /^symbol|zapfdingbats$/i #!# unless "#{font['enc']}".empty? #!# what about "/Differences"???
      if @core_fonts[font['font']]
        out(">>")
        end_obj
        next
      end
      out("/FirstChar 32 /LastChar 255")
      out("/FontDescriptor #{ref + 1} 0 R")
      out("/Widths #{ref + 2} 0 R")
      out(">>")
      end_obj

      # descriptor
      new_obj
      out("<<")
      out("/Type /FontDescriptor")
      out("/FontName /#{font['name']}")
      out("/FontFile#{font['type'] == 'Type1' ? '' : '2'} #{ref + 3} 0 R") #!# make a lookup hash?
      font['desc'].sort.each {|key, val| out("/#{key} #{val}")}
      out(">>")
      end_obj

      # widths
      new_obj
      size = font['cw']
      list = (32..255).map {|num| size[num]}
      out("[ #{list.join(' ')} ]")
      end_obj

      # file
      new_obj
      path = File.join(@path, font['file'])
      size = File.size(path)
      out("<<")
      out("/Filter /FlateDecode") if path[-2, 2] == '.z'
      out("/Length #{size}")
      out("/Length1 #{font['len1']}")
      out("/Length2 #{font['len2']} /Length3 0") if font['len2']
      out(">>")
      out_stream(File.open(path, "rb") {|f| f.read})
      end_obj
    end
  end

  def out_images
    @images.values.sort{|a,b| a['i'] <=> b['i']}.each do |info|
      info['n'] = ref = new_obj

      # image
      out("<<")
      out("/Type /XObject")
      out("/Subtype /Image")
      out("/Width #{info['w']}")
      out("/Height #{info['h']}")
      out("/ColorSpace [/Indexed /DeviceRGB #{info['pal'].length / 3 - 1} #{ref + 1} 0 R]") if info['cs'] == 'Indexed'
      out("/ColorSpace /#{info['cs']}") if info['cs'] != 'Indexed'
      out("/Decode [1 0 1 0 1 0 1 0]") if info['cs'] == 'DeviceCMYK'
      out("/BitsPerComponent #{info['bpc']}")
      case info['type']
      when 'jpg'
        out("/Filter /DCTDecode")
      when 'png'
        out("/Filter /FlateDecode")
        out("/DecodeParms")
        out("<<")
        out("/Predictor 15")
        out("/Colors %d" % (info['cs'] == 'DeviceRGB' ? 3 : 1))
        out("/BitsPerComponent %d" % info['bpc'])
        out("/Columns %d" % info['w'])
        out(">>")
      end
      out("/Length #{info['data'].size}")
      out(">>")
      out_stream(info['data'])
      end_obj

      # palette
      pal = info['pal'] or next
      pal = Zlib::Deflate.deflate(pal) if @compress
      new_obj
      out("<<")
      out("/Filter /FlateDecode") if @compress
      out("/Length #{pal.size}")
      out(">>")
      out_stream(pal)
      end_obj
    end
  end

  def out_resources
    new_obj
    out("<<")
    out("/ProcSet [/PDF /Text /ImageB /ImageC /ImageI]")
    unless @fonts.empty?
      out("/Font")
      out("<<")
      @fonts.values.sort{|a,b| a['i'] <=> b['i']}.each do |font|
        out("/F#{font['i']} #{font['n']} 0 R")
      end
      out(">>")
    end
    unless @images.empty?
      out("/XObject")
      out("<<")
      @images.values.sort{|a,b| a['i'] <=> b['i']}.each do |image|
        out("/I#{image['i']} #{image['n']} 0 R")
      end
      out(">>")
    end
    out(">>")
    end_obj
  end

  def out_xrefs
    @xref = @buffer.length
    out("xref")
    out("0 #{@offsets.size + 1}")
    out("0000000000 65535 f ")
    @offsets.each {|offset| out("%010d 00000 n " % offset)}
  end

  def out_trailer
    @xref or raise "@xref not defined"
    out("trailer")
    out("<<")
    out("/Info 1 0 R")
    out("/Root 2 0 R")
    out("/Size #{@offsets.size + 1}")
    out(">>")
    out("startxref")
    out(@xref)
    out("%%EOF")
  end

  # ==[ Pages ]================================================================

  def page(orientation='')
    @pages[@page += 1] = ''
    @state = 2 # in-page
    @colors['line'] = @colors['area'] = '0'
    @x = @margins['left']
    @y = @margins['top']

    #!# handle orientations and changes
    # out('2 J') # set line cap style to "projecting square cap" (if it's not 0)
    # out('%.3f w' % (@thick * @scale)) # line width (if it's not 1pt)

    out_font(@font['i'], @size)
  end

  def goto(x=nil,y=nil)
    @x, x = @margins['left'], nil if x == '' # x='' moves to left margin
    @y, y = @y + @size      , nil if y == '' # y='' moves to top-align text
    @x = (x < 0) ? (@wide - @scale * x) : (@scale * x) if x
    @y = (y < 0) ? (@tall - @scale * y) : (@scale * y) if y
  end

  def x(x=nil)
    @x = x if x
    @x
  end

  def y(y=nil)
    @y = y
    @y
  end

  def margins(*list)
    list = list.flatten.map {|num| num.to_f * @scale}
    case list.size
    when 0
      return @margins
    when 1
      @margins['top'] = @margins['right'] = @margins['bottom'] = @margins['left'] = list[0]
    when 2, 3
      @margins['top'] = @margins['bottom'] = list[0]
      @margins['right'] = @margins['left'] = list[1]
      @margins['cell'] = list.last if list.size == 3
    when 4, 5
      @margins['top'], @margins['right'], @margins['bottom'], @margins['left'] = list
      @margins['cell'] = list.last if list.size == 5
    else raise "invalid margins specified #{list.inspect}"
    end
    nil
  end

  # ==[ Colors ]===============================================================

  def float(val, fmt="%.3f")
    case val
    when 0,[0,0,0]       then "0"
    when 1, 255          then "1"
    when 1..255          then fmt % (val / (val % 16 == 0 ? 256.0 : 255.0))
    when 0..1            then fmt % val
    when Array           then val.size == 3 ? val.map {|x| float(x)}.join(' ') : raise
    when /^[\da-f]{6}$/i then val.scan(/../).map {|x| float(( x ).hex)}.join(' ')
    when /^[\da-f]{3}$/i then val.scan(/./ ).map {|x| float((x+x).hex)}.join(' ')
    else raise
    end
  rescue
    raise "unable to parse float value #{val.inspect}"
  end

  def colors(*args)
    type = 'font'
    args.each do |arg|
      case arg
      when 'draw', 'fill', 'font' then type = arg
      when Symbol                 then type = arg.to_s; redo
      when Numeric, Array, String then @colors[type] = float(arg)
      when Hash                   then colors(arg.to_a.flatten)
      else raise "unable to parse color #{arg.inspect}"
      end
    end
  end

  def drawcolor(val); @colors['draw'] = float(val); end
  def fillcolor(val); @colors['fill'] = float(val); end
  def fontcolor(val); @colors['font'] = float(val); end #!# should this be "textcolor"???

  # ==[ Shapes ]===============================================================

  def fill(x, y, w, h)
    x = x ?         x * @scale : @x
    y = y ? @tall - y * @scale : @y
    w =             w * @scale
    h =             h * @scale

    area, fill = @colors['area'], @colors['fill']
    out_fill_color(@colors['area'] = fill) if fill && fill != area
    out_rect(x, y, w, -h, 'f')
  end

  def draw(x, y, w, h)
    line = @thick
    half = 0.5 * line

    x = (x ?         x * @scale : @x) + half
    y = (y ? @tall - y * @scale : @y) - half
    w = (            w * @scale     ) - line
    h = (            h * @scale     ) - line

    line, draw = @colors['line'], @colors['draw']
    out_line_color(@colors['line'] = draw) if draw && draw != line
    out_rect(x, y, w, -h, 'd')
  end

  def line(*args)
    line = @thick
    half = 0.5 * line

    case args.size
    when 0
      x1 = @margins['left']            + half
      x2 = @wide - @margins['right']   - half
      y1 = y2 = @tall - @y             - half
    when 1
      if (w = args[0]) < 0
        x2 = @wide - @margins['right'] - half
        x1 = x2 - w                    + line
      else
        x1 = @x                        + half
        x2 = x1 + args[0] * @scale     - line
      end
      y1 = y2 = @tall - @y             - half
    when 4
      x1, y1, x2, y2 = *args.map {|val| val * @scale}
      y1 = @tall - y1
      y2 = @tall - y2
    else
      raise "invalid line arg #{arg.inspect}"
    end
    line, draw = @colors['line'], @colors['draw']
    out_line_color(@colors['line'] = draw) if draw && draw != line
    out_line(x1, y1, x2, y2)
  end

  # ==[ Text ]=================================================================

  def width(text)
    size = @font['cw']
    wide = text.unpack("C*").inject(0) {|wide, char| wide += size[char]}
    wide * @size / 1000.0 # in pts
  end

  def height(val=nil)
    @high = val if val
    @high
  end

  def spacing(val=nil)
    if val
      @spacing = val
      height(@size * @spacing * 1.2)
    end
    @spacing
  end

  def string(str)
    "(#{escape(str)})"
  end

  def escape(str)
    str.gsub("\\","\\\\").gsub("(","\\(").gsub(")","\\)")
  end

  def print(text, eols=0)
    if @margins['bottom'] >= @tall - @y
      page
      header if respond_to?(:header)
    end
    if text != ''
      line, draw = @colors['line'], @colors['draw']
      area, font = @colors['area'], @colors['font']
      out_line_color(@colors['line'] = draw) if draw && draw != line
      out_fill_color(@colors['area'] = font) if font && font != area
      out_text(@x, @tall - @y, escape(text))
      if @underline
        drop = @font['up']
        line = @font['ut']
        wide = width(text) #!# handle wordspacing => + @word_spacing * str.count(' ')
        out_rect(@x, @tall - @y + drop / 1000.0 * @size, wide, -line / 1000.0 * @size, 'f')
      end
    end
    if eols > 0
      @y += @high * eols
      @x = @margins['left']
    else
      @x += wide || width(text)
    end
  end

  def puts(text='', eols=1)
    print(text, eols)
  end

  def text(x=nil, y=nil, text='', eols=0)
    goto(x, y) if x || y
    print(text, eols)
  end

  def center(text, left=nil, right=nil, eols=0)
    left  ||= @margins['left']
    right ||= @wide - @margins['right']
    rows = text.split("\n",-1)
    last = rows.size - 1
    rows.each_with_index do |line, i|
      goto((right + left - width(line)) / 2.0)
      print(line, i == last ? eols : 1)
    end
  end

  def wrap(text, eols=1)
    side = @wide - @margins['right']
    list = text.split(/[ \t]*\n/)
    if list.empty?
      print('', eols)
      return
    end
    last = list.size - 1
    list.each_with_index do |line, i|
      line.gsub!("\t", "     ") # HACK: tab expands to five spaces

      # plenty of room
      if (@x + width(line) <= side)
        print(line, i == last ? eols : 1)
        next
      end

      # requires word wrap
      posn = @x
      show = ""
      line.scan(/\G(\s*)(\S+)/) do |fill, word|
        lead = width(fill)
        wide = width(word)
        if (posn + lead + wide <= side)
          posn += lead + wide
          show += fill + word
        else
          print(show, i == last ? eols : 1)
          posn = @x
          if (posn + wide <= side)
            posn += wide
            show = word
          else
            raise "word split not yet implemented"
          end
        end
      end
      print(show, eols) unless show.empty?
    end
  end

  def table(y, cols, rows)
    wide = cols.size
    bold = cols.map {|col| col.is_a?(Array)}
    cols = cols.flatten
    last = nil

    n = 0
    rows.each_slice(wide) do |list|
      cols.each_with_index do |x, i|
        item = list[i].to_s
        next if item.empty?
        if last != bold[i]
          font(last ? '' : 'B')
          last = !last
        end
        text(x, y + n * @high, item)
      end
      n += 1
    end
    font('')
  end

  def indent(far=[1])
    far = case far
      when false, nil then return block_given? ? yield : nil
      when "@"        then @x - @indents.last
      when Numeric    then far * @scale
      when Array      then far[0] * @tab
      when String     then far.to_f * @scale - @indents.last
      when true       then @tab
      else raise "invalid indent value #{far.inspect}"
    end
    @x = @margins['left'] = @indents.last + far
    @indents.push(@x)
    if block_given?
      yield
      undent
    end
  end

  def undent(num=1)
    @indents.slice!(-num, num)
    @x = @margins['left'] = @indents.last || raise("too many undents!")
  end

  # ==[ Fonts ]================================================================

  def font(*args, &block)
    define_core_fonts unless @core_fonts

    # current font
    font = @font['font'] || ''
    orig = [@font, @size, @underline, @high]
    name = font.sub(/[BI]+$/,'')
    type = font[/[BI]*$/] + (@underline ? 'U' : '')

    # grok request (may update @size and @underline)
    path = nil
    args.each do |arg|
      case arg
      when Numeric     then @size = arg; spacing(@spacing)
      when ''          then type = arg
      when /^[biu]+$/i then type = arg.upcase.split('').sort.uniq.join('')
      when /[\/\\]/    then path = arg
      when String      then name = arg.downcase.delete(' ')
      when Array       then fontcolor(arg[0].is_a?(Array) ? arg[0] : arg)
      else raise "unknown font argument #{arg.inspect}"
      end
    end
    @underline = !!type.delete!('U')
    font = "#{name}#{type}"

    # pull font
    @font = case
    when @fonts[font]
      @fonts[font]
    when @core_fonts[font]
      @fonts[font] = {
        'i'    => @fonts.size + 1,
        'font' => font,
        'name' => @core_fonts[font],
        'type' => 'Type1',
        'up'   => -100,
        'ut'   => 50,
        'cw'   => @char_width[font],
      }
    else
      load(path ||= "#{font.downcase}.rb") #!# can we use a require instead of load?
      @fonts[font] = {
        'i'    => @fonts.size + 1,
        'font' => font,
        'name' => FontDef.name,
        'type' => FontDef.type,
        'up'   => FontDef.up,
        'ut'   => FontDef.ut,
        'cw'   => FontDef.cw,
        'file' => FontDef.file,
        'enc'  => FontDef.enc,
        'desc' => FontDef.desc,
        'len1' => FontDef.type == 'TrueType' ? FontDef.originalsize : FontDef.size1,
        'len2' => FontDef.type == 'TrueType' ? nil                  : FontDef.size2,
      }
    end

    # change font
    if [@font['i'], @size] != [orig[0]['i'], orig[1]]
      out_font(@font['i'], @size)
      changed = true
    end

    # call block and restore context
    if block_given?
      instance_eval(&block) #!# should this just be 'yield' ???
      @font, @size, @underline, @high = orig
      out_font(@font['i'], @size) if changed
    end
  end

  def bold(*args, &block)
    font(*args.push('b'), &block)
  end

  # ==[ Images ]===============================================================

  def image(path, x=nil, y=nil, w=0, h=0)
    if @images[path]
      info = @images[path]
    else
      info = case path
        when /\.jpe?g$/i then parse_jpg(path)
        when /\.png$/i   then parse_png(path)
        else raise "unable to determine image type for #{path.inspect}"
      end
      info['i'] = @images.size + 1
      @images[path] = info
    end

    # determine aspect ratio if needed
    if w == 0 && h == 0
      w = info['w'] / @dpi * 72.0 / @scale
      h = info['h'] / @dpi * 72.0 / @scale
    elsif w == 0
      w = h.to_f * info['w'] / info['h']
    elsif h == 0
      h = w.to_f * info['h'] / info['w']
    end

    # (nil) for inline, (-x) for right-align, (-y) to top-align
    x ||= @x / @scale
    y ||= @y / @scale
    y = h - y if y <= 0 # -0.0 will flush image to top of page
    x =-x - w if x <= 0 # -0.0 seems a little pointless here

    args = [w, h, x, -y].map {|val| val * @scale}; args[-1] += @tall
    out_image(*args.push(info['i']))
  end

  def get_int(file)
    file.read(4).unpack('N')[0]
  end

  def get_short(file)
    file.read(2).unpack('n')[0]
  end

  def get_byte(file)
    file.read(1).unpack('C')[0]
  end

  def get_mark(file)
#   file.gets("\xFF") #!# Fixed in JRuby 1.5 => http://jira.codehaus.org/browse/JRUBY-4416
    until (byte = get_byte(file)) == 255; end #!# Remove this for JRuby 1.5
    until (byte = get_byte(file)) > 0; end
    byte
  end

  def parse_jpg(path)
    info = {}

    open(path, "rb") do |file|
      get_mark(file) == 0xd8 or raise "invalid JPG file #{path.inspect}" # SOI
      loop do
        case get_mark(file)
        when 0xd9, 0xda then break # EOI, SOS
        when 0xc0..0xc3, 0xc5..0xc7, 0xc9..0xcb, 0xcd..0xcf # SOF
          size = get_short(file)
          if info.empty?
            info['bpc'] = get_byte(file)
            info['h'  ] = get_short(file)
            info['w'  ] = get_short(file)
            info['cs' ] = case get_byte(file)
              when 3 then 'DeviceRGB'
              when 4 then 'DeviceCMYK'
              else        'DeviceGray'
            end
            file.seek(size - 8, IO::SEEK_CUR)
          else
            file.seek(size - 2, IO::SEEK_CUR)
          end
        else
          size = get_short(file)
          file.seek(size - 2, IO::SEEK_CUR)
        end
      end
    end

    info.update('type' => 'jpg', 'data' => File.open(path, 'rb') {|f| f.read})
  end

  def parse_png(path)
    info = {}

    open(path, "rb") do |file|
      file.read(8) == "\x89PNG\r\n\cZ\n" or raise "invalid PNG file #{path.inspect}"
      file.read(4)
      file.read(4) == "IHDR" or raise "invalid PNG file #{path.inspect}"

      info['w'  ] = get_int(file)
      info['h'  ] = get_int(file)
      info['bpc'] = get_byte(file)
      info['cs' ] = case (ct=get_byte(file))
        when 0 then 'DeviceGray'
        when 2 then 'DeviceRGB'
        when 3 then 'Indexed'
        else raise "unable to support PNG alpha channels"
      end

      info['bpc'] > 8    and raise "unable to support >8-bit color in file #{path.inspect}"
      get_byte(file) == 0 or raise "unknown compression method in file #{path.inspect}"
      get_byte(file) == 0 or raise "unknown filter method in file #{path.inspect}"
      get_byte(file) == 0 or raise "unable to support interlacing in file #{path.inspect}"
      file.read(4)

      loop do
        size = get_int(file)
        type = file.read(4)
        case type
        when 'IEND' then break
        when 'PLTE'
          info['pal'] = file.read(size)
          file.read(4)
        when 'tRNS'
          trns = file.read(size)
          case ct
            when 0 then info['trns'] = [trns[1]]
            when 2 then info['trns'] = [trns[1], trns[3], trns[5]]
            else info['trns'] = [trns.index(0)] #!# this may be wrong...
          end
          file.read(4)
        when 'IDAT'
          (info['data'] ||= "") << file.read(size)
          file.read(4)
        else
          file.seek(size + 4, IO::SEEK_CUR)
        end
      end
    end

    raise "missing palette in file #{path.inspect}" if info['cs'] == 'Indexed' && !info['pal']

    info.update('type' => 'png')
  end

  # ==[ Core fonts ]===========================================================

  def define_core_fonts
    @core_fonts = {
      'courier'      => 'Courier',
      'courierB'     => 'Courier-Bold',
      'courierBI'    => 'Courier-BoldOblique',
      'courierI'     => 'Courier-Oblique',
      'helvetica'    => 'Helvetica',
      'helveticaB'   => 'Helvetica-Bold',
      'helveticaBI'  => 'Helvetica-BoldOblique',
      'helveticaI'   => 'Helvetica-Oblique',
      'symbol'       => 'Symbol',
      'times'        => 'Times-Roman',
      'timesB'       => 'Times-Bold',
      'timesBI'      => 'Times-BoldItalic',
      'timesI'       => 'Times-Italic',
      'zapfdingbats' => 'ZapfDingbats',
    }

    @char_width = {
      'courier'      => [600] * 256,
      'courierB'     => [600] * 256,
      'courierI'     => [600] * 256,
      'courierBI'    => [600] * 256,
      'helvetica'    => [278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 350, 556, 350, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500],
      'helveticaB'   => [278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 350, 556, 350, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278, 611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556],
      'helveticaI'   => [278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, 350, 556, 350, 222, 556, 333, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 222, 222, 333, 333, 350, 556, 1000, 333, 1000, 500, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 260, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 556, 537, 278, 333, 333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556, 278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556, 500, 556, 500],
      'helveticaBI'  => [278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, 350, 556, 350, 278, 556, 500, 1000, 556, 556, 333, 1000, 667, 333, 1000, 350, 611, 350, 350, 278, 278, 500, 500, 350, 556, 1000, 333, 1000, 556, 333, 944, 350, 500, 667, 278, 333, 556, 556, 556, 556, 280, 556, 333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 611, 556, 278, 333, 333, 365, 556, 834, 834, 834, 611, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722, 722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556, 278, 278, 278, 278, 611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611, 556, 611, 556],
      'times'        => [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, 556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, 333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, 500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541, 350, 500, 350, 333, 500, 444, 1000, 500, 500, 333, 1000, 556, 333, 889, 350, 611, 350, 350, 333, 333, 444, 444, 350, 500, 1000, 333, 980, 389, 333, 722, 350, 444, 722, 250, 333, 500, 500, 500, 500, 200, 500, 333, 760, 276, 500, 564, 333, 760, 333, 400, 564, 300, 300, 333, 500, 453, 250, 333, 300, 310, 500, 750, 750, 750, 444, 722, 722, 722, 722, 722, 722, 889, 667, 611, 611, 611, 611, 333, 333, 333, 333, 722, 722, 722, 722, 722, 722, 722, 564, 722, 722, 722, 722, 722, 722, 556, 500, 444, 444, 444, 444, 444, 444, 667, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 564, 500, 500, 500, 500, 500, 500, 500, 500],
      'timesB'       => [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 333, 555, 500, 500, 1000, 833, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 930, 722, 667, 722, 722, 667, 611, 778, 778, 389, 500, 778, 667, 944, 722, 778, 611, 778, 722, 556, 667, 722, 722, 1000, 722, 722, 667, 333, 278, 333, 581, 500, 333, 500, 556, 444, 556, 444, 333, 500, 556, 278, 333, 556, 278, 833, 556, 500, 556, 556, 444, 389, 333, 556, 500, 722, 500, 500, 444, 394, 220, 394, 520, 350, 500, 350, 333, 500, 500, 1000, 500, 500, 333, 1000, 556, 333, 1000, 350, 667, 350, 350, 333, 333, 500, 500, 350, 500, 1000, 333, 1000, 389, 333, 722, 350, 444, 722, 250, 333, 500, 500, 500, 500, 220, 500, 333, 747, 300, 500, 570, 333, 747, 333, 400, 570, 300, 300, 333, 556, 540, 250, 333, 300, 330, 500, 750, 750, 750, 500, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 389, 389, 389, 389, 722, 722, 778, 778, 778, 778, 778, 570, 778, 722, 722, 722, 722, 722, 611, 556, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556, 500, 556, 500],
      'timesI'       => [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 333, 420, 500, 500, 833, 778, 214, 333, 333, 500, 675, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 675, 675, 675, 500, 920, 611, 611, 667, 722, 611, 611, 722, 722, 333, 444, 667, 556, 833, 667, 722, 611, 722, 611, 500, 556, 722, 611, 833, 611, 556, 556, 389, 278, 389, 422, 500, 333, 500, 500, 444, 500, 444, 278, 500, 500, 278, 278, 444, 278, 722, 500, 500, 500, 500, 389, 389, 278, 500, 444, 667, 444, 444, 389, 400, 275, 400, 541, 350, 500, 350, 333, 500, 556, 889, 500, 500, 333, 1000, 500, 333, 944, 350, 556, 350, 350, 333, 333, 556, 556, 350, 500, 889, 333, 980, 389, 333, 667, 350, 389, 556, 250, 389, 500, 500, 500, 500, 275, 500, 333, 760, 276, 500, 675, 333, 760, 333, 400, 675, 300, 300, 333, 500, 523, 250, 333, 300, 310, 500, 750, 750, 750, 500, 611, 611, 611, 611, 611, 611, 889, 667, 611, 611, 611, 611, 333, 333, 333, 333, 722, 667, 722, 722, 722, 722, 722, 675, 722, 722, 722, 722, 722, 556, 611, 500, 500, 500, 500, 500, 500, 500, 667, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 675, 500, 500, 500, 500, 500, 444, 500, 444],
      'timesBI'      => [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 389, 555, 500, 500, 833, 778, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 832, 667, 667, 667, 722, 667, 667, 722, 778, 389, 500, 667, 611, 889, 722, 722, 611, 722, 667, 556, 611, 722, 667, 889, 667, 611, 611, 333, 278, 333, 570, 500, 333, 500, 500, 444, 500, 444, 333, 500, 556, 278, 278, 500, 278, 778, 556, 500, 500, 500, 389, 389, 278, 556, 444, 667, 500, 444, 389, 348, 220, 348, 570, 350, 500, 350, 333, 500, 500, 1000, 500, 500, 333, 1000, 556, 333, 944, 350, 611, 350, 350, 333, 333, 500, 500, 350, 500, 1000, 333, 1000, 389, 333, 722, 350, 389, 611, 250, 389, 500, 500, 500, 500, 220, 500, 333, 747, 266, 500, 606, 333, 747, 333, 400, 570, 300, 300, 333, 576, 500, 250, 333, 300, 300, 500, 750, 750, 750, 500, 667, 667, 667, 667, 667, 667, 944, 667, 667, 667, 667, 667, 389, 389, 389, 389, 722, 722, 722, 722, 722, 722, 722, 570, 722, 722, 722, 722, 722, 611, 611, 500, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556, 444, 500, 444],
      'symbol'       => [250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 333, 713, 500, 549, 833, 778, 439, 333, 333, 500, 549, 250, 549, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 549, 549, 549, 444, 549, 722, 667, 722, 612, 611, 763, 603, 722, 333, 631, 722, 686, 889, 722, 722, 768, 741, 556, 592, 611, 690, 439, 768, 645, 795, 611, 333, 863, 333, 658, 500, 500, 631, 549, 549, 494, 439, 521, 411, 603, 329, 603, 549, 549, 576, 521, 549, 549, 521, 549, 603, 439, 576, 713, 686, 493, 686, 494, 480, 200, 480, 549, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 750, 620, 247, 549, 167, 713, 500, 753, 753, 753, 753, 1042, 987, 603, 987, 603, 400, 549, 411, 549, 549, 713, 494, 460, 549, 549, 549, 549, 1000, 603, 1000, 658, 823, 686, 795, 987, 768, 768, 823, 768, 768, 713, 713, 713, 713, 713, 713, 713, 768, 713, 790, 790, 890, 823, 549, 250, 713, 603, 603, 1042, 987, 603, 987, 603, 494, 329, 790, 790, 786, 713, 384, 384, 384, 384, 384, 384, 494, 494, 494, 494, 0, 329, 274, 686, 686, 686, 384, 384, 384, 384, 384, 384, 494, 494, 494, 0],
      'zapfdingbats' => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 278, 974, 961, 974, 980, 719, 789, 790, 791, 690, 960, 939, 549, 855, 911, 933, 911, 945, 974, 755, 846, 762, 761, 571, 677, 763, 760, 759, 754, 494, 552, 537, 577, 692, 786, 788, 788, 790, 793, 794, 816, 823, 789, 841, 823, 833, 816, 831, 923, 744, 723, 749, 790, 792, 695, 776, 768, 792, 759, 707, 708, 682, 701, 826, 815, 789, 789, 707, 687, 696, 689, 786, 787, 713, 791, 785, 791, 873, 761, 762, 762, 759, 759, 892, 892, 788, 784, 438, 138, 277, 415, 392, 392, 668, 668, 0, 390, 390, 317, 317, 276, 276, 509, 509, 410, 410, 234, 234, 334, 334, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 732, 544, 544, 910, 667, 760, 760, 776, 595, 694, 626, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 788, 894, 838, 1016, 458, 748, 924, 748, 918, 927, 928, 928, 834, 873, 828, 924, 924, 917, 930, 931, 463, 883, 836, 836, 867, 867, 696, 696, 874, 0, 874, 760, 946, 771, 865, 771, 888, 967, 888, 831, 873, 927, 970, 918, 0]
    }
  end

end

__END__

# Interesting...
q                                              % Save graphics state
  1       0        0       1       100 200  cm % Translate
  0.7071  0.7071  -0.7071  0.7071  0   0    cm % Rotate
  150     0        0       80      0   0    cm % Scale
  /Image1 Do                                   % Paint image
Q                                              % Restore graphics state

# Future...
Link
Cell
private/public
