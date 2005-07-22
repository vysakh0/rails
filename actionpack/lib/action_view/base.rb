require 'erb'

module ActionView #:nodoc:
  class ActionViewError < StandardError #:nodoc:
  end

  # Action View templates can be written in two ways. If the template file has a +.rhtml+ extension then it uses a mixture of ERb 
  # (included in Ruby) and HTML. If the template file has a +.rxml+ extension then Jim Weirich's Builder::XmlMarkup library is used.  
  # 
  # = ERb
  # 
  # You trigger ERb by using embeddings such as <% %> and <%= %>. The difference is whether you want output or not. Consider the 
  # following loop for names:
  #
  #   <b>Names of all the people</b>
  #   <% for person in @people %>
  #     Name: <%= person.name %><br/>
  #   <% end %>
  #
  # The loop is setup in regular embedding tags (<% %>) and the name is written using the output embedding tag (<%= %>). Note that this
  # is not just a usage suggestion. Regular output functions like print or puts won't work with ERb templates. So this would be wrong:
  #
  #   Hi, Mr. <% puts "Frodo" %>
  #
  # (If you absolutely must write from within a function, you can use the TextHelper#concat)
  #
  # == Using sub templates
  #
  # Using sub templates allows you to sidestep tedious replication and extract common display structures in shared templates. The
  # classic example is the use of a header and footer (even though the Action Pack-way would be to use Layouts):
  #
  #   <%= render "shared/header" %>
  #   Something really specific and terrific
  #   <%= render "shared/footer" %>
  #
  # As you see, we use the output embeddings for the render methods. The render call itself will just return a string holding the
  # result of the rendering. The output embedding writes it to the current template.
  #
  # But you don't have to restrict yourself to static includes. Templates can share variables amongst themselves by using instance
  # variables defined in using the regular embedding tags. Like this:
  #
  #   <% @page_title = "A Wonderful Hello" %>
  #   <%= render "shared/header" %>
  #
  # Now the header can pick up on the @page_title variable and use it for outputting a title tag:
  #
  #   <title><%= @page_title %></title>
  #
  # == Passing local variables to sub templates
  # 
  # You can pass local variables to sub templates by using a hash with the variable names as keys and the objects as values:
  #
  #   <%= render "shared/header", { "headline" => "Welcome", "person" => person } %>
  #
  # These can now be accessed in shared/header with:
  #
  #   Headline: <%= headline %>
  #   First name: <%= person.first_name %>
  #
  # == Template caching
  #
  # The parsing of ERb templates are cached by default, but the reading of them are not. This means that the application by default
  # will reflect changes to the templates immediatly. If you'd like to sacrifice that immediacy for the speed gain given by also
  # caching the loading of templates (reading from the file system), you can turn that on with 
  # <tt>ActionView::Base.cache_template_loading = true</tt>.
  #
  # == Builder
  #
  # Builder templates are a more programmatic alternative to ERb. They are especially useful for generating XML content. An +XmlMarkup+ object 
  # named +xml+ is automatically made available to templates with a +.rxml+ extension. 
  #
  # Here are some basic examples:
  #
  #   xml.em("emphasized")                              # => <em>emphasized</em>
  #   xml.em { xml.b("emp & bold") }                    # => <em><b>emph &amp; bold</b></em>
  #   xml.a("A Link", "href"=>"http://onestepback.org") # => <a href="http://onestepback.org">A Link</a>
  #   xm.target("name"=>"compile", "option"=>"fast")    # => <target option="fast" name="compile"\>
  #                                                     # NOTE: order of attributes is not specified.
  # 
  # Any method with a block will be treated as an XML markup tag with nested markup in the block. For example, the following:
  #
  #   xml.div {
  #     xml.h1(@person.name)
  #     xml.p(@person.bio)
  #   }
  #
  # would produce something like:
  #
  #   <div>
  #     <h1>David Heinemeier Hansson</h1>
  #     <p>A product of Danish Design during the Winter of '79...</p>
  #   </div>
  #
  # A full-length RSS example actually used on Basecamp:
  #
  #   xml.rss("version" => "2.0", "xmlns:dc" => "http://purl.org/dc/elements/1.1/") do
  #     xml.channel do
  #       xml.title(@feed_title)
  #       xml.link(@url)
  #       xml.description "Basecamp: Recent items"
  #       xml.language "en-us"
  #       xml.ttl "40"
  # 
  #       for item in @recent_items
  #         xml.item do
  #           xml.title(item_title(item))
  #           xml.description(item_description(item)) if item_description(item)
  #           xml.pubDate(item_pubDate(item))
  #           xml.guid(@person.firm.account.url + @recent_items.url(item))
  #           xml.link(@person.firm.account.url + @recent_items.url(item))
  #       
  #           xml.tag!("dc:creator", item.author_name) if item_has_creator?(item)
  #         end
  #       end
  #     end
  #   end
  #
  # More builder documentation can be found at http://builder.rubyforge.org.
  class Base
    include ERB::Util
    
    attr_reader   :first_render
    attr_accessor :base_path, :assigns, :template_extension
    attr_accessor :controller
    
    attr_reader :logger, :params, :response, :session, :headers, :flash

    # Turn on to cache the reading of templates from the file system. Doing so means that you have to restart the server
    # when changing templates, but that rendering will be faster.
    @@cache_template_loading = false
    cattr_accessor :cache_template_loading

    # Specify trim mode for the ERB compiler. Defaults to '-'.
    # See ERB documentation for suitable values.
    @@erb_trim_mode = '-'
    cattr_accessor :erb_trim_mode

    @@compiled_erb_templates = {}
    @@erb_count = 0
    @@loaded_templates = {}
    @@template_handlers = {}

    def self.load_helpers(helper_dir)#:nodoc:
      Dir.foreach(helper_dir) do |helper_file| 
        next unless helper_file =~ /_helper.rb$/
        require helper_dir + helper_file
        helper_module_name = helper_file.capitalize.gsub(/_([a-z])/) { |m| $1.capitalize }[0..-4]

        class_eval("include ActionView::Helpers::#{helper_module_name}") if Helpers.const_defined?(helper_module_name)
      end
    end

    def self.register_template_handler(extension, klass)
      @@template_handlers[extension] = klass
    end

    def initialize(base_path = nil, assigns_for_first_render = {}, controller = nil)#:nodoc:
      @base_path, @assigns = base_path, assigns_for_first_render
      @controller = controller
      @logger = controller && controller.logger 
    end

    # Renders the template present at <tt>template_path</tt>. If <tt>use_full_path</tt> is set to true, 
    # it's relative to the template_root, otherwise it's absolute. The hash in <tt>local_assigns</tt> 
    # is made available as local variables.
    def render_file(template_path, use_full_path = true, local_assigns = {})
      @first_render      = template_path if @first_render.nil?
      
      if use_full_path
        template_extension = pick_template_extension(template_path)
        template_file_name = full_template_path(template_path, template_extension)
      else
        template_file_name = template_path
        template_extension = template_path.split('.').last
      end
      
      template_source = read_template_file(template_file_name, template_extension)

      begin
        render_template(template_extension, template_source, template_file_name, local_assigns)
      rescue Exception => e
        if TemplateError === e
          e.sub_template_of(template_file_name)
          raise e
        else
          raise TemplateError.new(@base_path, template_file_name, @assigns, template_source, e)
        end
      end
    end
    
    # Renders the template present at <tt>template_path</tt> (relative to the template_root). 
    # The hash in <tt>local_assigns</tt> is made available as local variables.
    def render(options = {}, old_local_assigns = {})
      if options.is_a?(String)
        render_file(options, true, old_local_assigns)
      elsif options.is_a?(Hash)
        options[:locals] ||= {}
        options[:use_full_path] = options[:use_full_path].nil? ? true : options[:use_full_path]
        
        if options[:file]
          render_file(options[:file], options[:use_full_path], options[:locals])
        elsif options[:partial] && options[:collection]
          render_partial_collection(options[:partial], options[:collection], options[:spacer_template], options[:locals])
        elsif options[:partial]
          render_partial(options[:partial], options[:object], options[:locals])
        elsif options[:inline]
          render_template(options[:type] || :rhtml, options[:inline], options[:locals] || {})
        end
      end
    end
    
    # Renders the +template+ which is given as a string as either rhtml or rxml depending on <tt>template_extension</tt>.
    # The hash in <tt>local_assigns</tt> is made available as local variables.
    def render_template(template_extension, template, file_name = nil, local_assigns = {})
       if handler = @@template_handlers[template_extension]
        delegate_render(handler, template, local_assigns)
      elsif template_extension == 'rxml'
        rxml_render(template_extension, template, file_name, local_assigns)
      else
        rhtml_render(template_extension, template, file_name, local_assigns)
      end
    end

    def pick_template_extension(template_path)#:nodoc:
      if match = delegate_template_exists?(template_path)
        match.first
      elsif erb_template_exists?(template_path)
        'rhtml'
      elsif builder_template_exists?(template_path)
        'rxml'
      else
        raise ActionViewError, "No rhtml, rxml, or delegate template found for #{template_path}"
      end
    end
 
    def delegate_template_exists?(template_path)#:nodoc:
      @@template_handlers.find { |k,| template_exists?(template_path, k) }
    end

    def erb_template_exists?(template_path)#:nodoc:
      template_exists?(template_path, 'rhtml')
    end

    def builder_template_exists?(template_path)#:nodoc:
      template_exists?(template_path, 'rxml')
    end

    def file_exists?(template_path)#:nodoc:
      erb_template_exists?(template_path) || builder_template_exists?(template_path) || delegate_template_exists?(template_path)
    end

    # Returns true is the file may be rendered implicitly.
    def file_public?(template_path)#:nodoc:
      template_path.split('/').last[0,1] != '_'
    end

    private
      def full_template_path(template_path, extension)
        "#{@base_path}/#{template_path}.#{extension}"
      end

      def template_exists?(template_path, extension)
        fp = full_template_path(template_path, extension)
        (@@cache_template_loading && @@loaded_templates.has_key?(fp)) || FileTest.exists?(fp)
      end

      def read_template_file(template_path, extension)
        info = @@loaded_templates[template_path]
        read_file = info.nil? || ( info.is_a?(Time) ?
                                   info < File.stat(template_path).mtime :
                                   !@@cache_template_loading )
        if read_file
          @@loaded_templates[template_path] = info = File.read(template_path)
          @@compiled_erb_templates[template_path] = nil if 'rhtml' == extension
        end
        info
      end

      def evaluate_assigns(local_assigns = {})
        @assigns.each { |key, value| instance_variable_set "@#{key}", value }
        saved_locals = {}
        local_assigns.each do |key, value|
          varstr = "@_#{key}_"
          saved_locals[varstr] = instance_variable_get varstr
          instance_variable_set varstr, value
          unless self.respond_to? key
            self.class.class_eval "def #{key}; #{varstr}; end" 
            self.class.class_eval "def #{key}=(v); #{varstr} = v; end" 
          end
        end

        saved_locals
      end

      def compile_erb_template(template, file_name)
        cache_name = file_name || template

        unless @@compiled_erb_templates[cache_name]
          erb = ERB.new(template, nil, @@erb_trim_mode)
          erb_name = 'run_erb_'
          if file_name
            i = file_name.index(@base_path)
            l = @base_path.length
            s_file_name = i ? file_name[i+l+1,file_name.length-l-1] : file_name
            s_file_name.sub!(/.rhtml$/,'')
            s_file_name.tr!('/:-', '_')
            s_file_name.gsub!(/[^a-zA-Z0-9_]/){|s| s[0].to_s}
            erb_name += s_file_name
          else
            @@erb_count += 1
            erb_name += @@erb_count.to_s
          end
          erb_def = "def #{erb_name}; #{erb.src}; end"
          eval erb_def rescue raise ActionViewError, "ERROR defining #{erb_name}: #{erb_def}"

          @@compiled_erb_templates[cache_name] = erb_name.intern
          @@loaded_templates[cache_name] = Time.now if file_name
          logger.debug "Compiled erb template #{cache_name}\n  ==> #{erb_name}" if logger
        end

        @@compiled_erb_templates[cache_name]
      end

      def rhtml_render(extension, template, file_name, local_assigns)
        render_sym = compile_erb_template(template, file_name)
        saved_locals = evaluate_assigns(local_assigns)
        result = self.send(render_sym)
        saved_locals.each { |k,v| instance_variable_set(k, v) }
        result
      end

      def rxml_render(extension, template, file_name, local_assigns)
        @controller.headers["Content-Type"] ||= 'text/xml'
        saved_locals = evaluate_assigns(local_assigns)
        xml = Builder::XmlMarkup.new(:indent => 2)
        result = eval(template, binding, '(template)(eval)', 1)
        saved_locals.each { |k,v| instance_variable_set(k,v) }
        result
      end

      def delegate_render(handler, template, local_assigns)
        handler.new(self).render(template, local_assigns)
      end
  end
end

require 'action_view/template_error'
