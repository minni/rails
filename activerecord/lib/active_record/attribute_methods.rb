require 'active_support/core_ext/enumerable'
require 'active_support/deprecation'

module ActiveRecord
  # = Active Record Attribute Methods
  module AttributeMethods #:nodoc:
    extend ActiveSupport::Concern
    include ActiveModel::AttributeMethods

    included do
      include Read
      include Write
      include BeforeTypeCast
      include Query
      include PrimaryKey
      include TimeZoneConversion
      include Dirty
      include Serialization

      # Returns the value of the attribute identified by <tt>attr_name</tt> after it has been typecast (for example,
      # "2004-12-12" in a data column is cast to a date object, like Date.new(2004, 12, 12)).
      # (Alias for the protected read_attribute method).
      alias [] read_attribute

      # Updates the attribute identified by <tt>attr_name</tt> with the specified +value+.
      # (Alias for the protected write_attribute method).
      alias []= write_attribute

      public :[], :[]=
    end

    module ClassMethods
      # Generates all the attribute related methods for columns in the database
      # accessors, mutators and query methods.
      def define_attribute_methods
        return if attribute_methods_generated?

        if base_class == self
          super(column_names)
          @attribute_methods_generated = true
        else
          base_class.define_attribute_methods
        end
      end

      def attribute_methods_generated?
        if base_class == self
          @attribute_methods_generated ||= false
        else
          base_class.attribute_methods_generated?
        end
      end

      def generated_attribute_methods
        @generated_attribute_methods ||= (base_class == self ? super : base_class.generated_attribute_methods)
      end

      def generated_external_attribute_methods
        @generated_external_attribute_methods ||= begin
          if base_class == self
            # We will define the methods as instance methods, but will call them as singleton
            # methods. This allows us to use method_defined? to check if the method exists,
            # which is fast and won't give any false positives from the ancestors (because
            # there are no ancestors).
            Module.new { extend self }
          else
            base_class.generated_external_attribute_methods
          end
        end
      end

      def undefine_attribute_methods
        if base_class == self
          super
          @attribute_methods_generated = false
        else
          base_class.undefine_attribute_methods
        end
      end

      def instance_method_already_implemented?(method_name)
        if dangerous_attribute_method?(method_name)
          raise DangerousAttributeError, "#{method_name} is defined by ActiveRecord"
        end

        super
      end

      # A method name is 'dangerous' if it is already defined by Active Record, but
      # not by any ancestors. (So 'puts' is not dangerous but 'save' is.)
      def dangerous_attribute_method?(method_name)
        active_record = ActiveRecord::Base
        superclass    = ActiveRecord::Base.superclass

        (active_record.method_defined?(method_name) ||
         active_record.private_method_defined?(method_name)) &&
        !superclass.method_defined?(method_name) &&
        !superclass.private_method_defined?(method_name)
      end

      def attribute_method?(attribute)
        super || (table_exists? && column_names.include?(attribute.to_s.sub(/=$/, '')))
      end

      # Returns an array of column names as strings if it's not
      # an abstract class and table exists.
      # Otherwise it returns an empty array.
      def attribute_names
        @attribute_names ||= if !abstract_class? && table_exists?
            column_names
          else
            []
          end
      end
    end

    # If we haven't generated any methods yet, generate them, then
    # see if we've created the method we're looking for.
    def method_missing(method, *args, &block)
      unless self.class.attribute_methods_generated?
        self.class.define_attribute_methods

        if respond_to_without_attributes?(method)
          send(method, *args, &block)
        else
          super
        end
      else
        super
      end
    end

    def attribute_missing(match, *args, &block)
      if self.class.columns_hash[match.attr_name]
        ActiveSupport::Deprecation.warn(
          "The method `#{match.method_name}', matching the attribute `#{match.attr_name}' has " \
          "dispatched through method_missing. This shouldn't happen, because `#{match.attr_name}' " \
          "is a column of the table. If this error has happened through normal usage of Active " \
          "Record (rather than through your own code or external libraries), please report it as " \
          "a bug."
        )
      end

      super
    end

    def respond_to?(name, include_private = false)
      self.class.define_attribute_methods unless self.class.attribute_methods_generated?
      super
    end

    # Returns true if the given attribute is in the attributes hash
    def has_attribute?(attr_name)
      @attributes.has_key?(attr_name.to_s)
    end

    # Returns an array of names for the attributes available on this object.
    def attribute_names
      @attributes.keys
    end

    # Returns a hash of all the attributes with their names as keys and the values of the attributes as values.
    def attributes
      Hash[@attributes.map { |name, _| [name, read_attribute(name)] }]
    end

    # Returns an <tt>#inspect</tt>-like string for the value of the
    # attribute +attr_name+. String attributes are truncated upto 50
    # characters, and Date and Time attributes are returned in the
    # <tt>:db</tt> format. Other attributes return the value of
    # <tt>#inspect</tt> without modification.
    #
    #   person = Person.create!(:name => "David Heinemeier Hansson " * 3)
    #
    #   person.attribute_for_inspect(:name)
    #   # => '"David Heinemeier Hansson David Heinemeier Hansson D..."'
    #
    #   person.attribute_for_inspect(:created_at)
    #   # => '"2009-01-12 04:48:57"'
    def attribute_for_inspect(attr_name)
      value = read_attribute(attr_name)

      if value.is_a?(String) && value.length > 50
        "#{value[0..50]}...".inspect
      elsif value.is_a?(Date) || value.is_a?(Time)
        %("#{value.to_s(:db)}")
      else
        value.inspect
      end
    end

    # Returns true if the specified +attribute+ has been set by the user or by a database load and is neither
    # nil nor empty? (the latter only applies to objects that respond to empty?, most notably Strings).
    def attribute_present?(attribute)
      value = read_attribute(attribute)
      !value.nil? || (value.respond_to?(:empty?) && !value.empty?)
    end

    # Returns the column object for the named attribute.
    def column_for_attribute(name)
      self.class.columns_hash[name.to_s]
    end

    protected

    def clone_attributes(reader_method = :read_attribute, attributes = {})
      attribute_names.each do |name|
        attributes[name] = clone_attribute_value(reader_method, name)
      end
      attributes
    end

    def clone_attribute_value(reader_method, attribute_name)
      value = send(reader_method, attribute_name)
      value.duplicable? ? value.clone : value
    rescue TypeError, NoMethodError
      value
    end

    # Returns a copy of the attributes hash where all the values have been safely quoted for use in
    # an Arel insert/update method.
    def arel_attributes_values(include_primary_key = true, include_readonly_attributes = true, attribute_names = @attributes.keys)
      attrs      = {}
      klass      = self.class
      arel_table = klass.arel_table

      attribute_names.each do |name|
        if (column = column_for_attribute(name)) && (include_primary_key || !column.primary)

          if include_readonly_attributes || !self.class.readonly_attributes.include?(name)

            value = if klass.serialized_attributes.include?(name)
                      @attributes[name].serialized_value
                    else
                      # FIXME: we need @attributes to be used consistently.
                      # If the values stored in @attributes were already type
                      # casted, this code could be simplified
                      read_attribute(name)
                    end

            attrs[arel_table[name]] = value
          end
        end
      end

      attrs
    end

    def attribute_method?(attr_name)
      attr_name == 'id' || (defined?(@attributes) && @attributes.include?(attr_name))
    end
  end
end
