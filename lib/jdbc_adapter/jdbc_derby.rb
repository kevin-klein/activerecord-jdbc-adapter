require 'jdbc_adapter/missing_functionality_helper'

module JdbcSpec
  module Derby
    def self.monkey_rails
      unless @already_monkeyd
        # Needed because Rails is broken wrt to quoting of 
        # some values. Most databases are nice about it,
        # but not Derby. The real issue is that you can't
        # compare a CHAR value to a NUMBER column.
        ::ActiveRecord::Associations::ClassMethods.module_eval do
          private

          def select_limited_ids_list(options, join_dependency)
            connection.select_all(
                                  construct_finder_sql_for_association_limiting(options, join_dependency),
                                  "#{name} Load IDs For Limited Eager Loading"
                                  ).collect { |row| connection.quote(row[primary_key], columns_hash[primary_key]) }.join(", ")
          end           
        end

        @already_monkeyd = true
      end
    end

    def self.extended(*args)
      monkey_rails
    end

    def self.included(*args)
      monkey_rails
    end
    
    module Column
      def type_cast(value)
        return nil if value.nil? || value =~ /^\s*null\s*$/i
        case type
        when :string    then value
        when :text    then value
        when :integer   then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :primary_key then defined?(value.to_i) ? value.to_i : (value ? 1 : 0) 
        when :decimal   then self.class.value_to_decimal(value)
        when :float     then value.to_f
        when :datetime  then cast_to_date_or_time(value)
        when :date      then self.class.string_to_date(value)
        when :timestamp then cast_to_time(value)
        when :binary    then value.scan(/[0-9A-Fa-f]{2}/).collect {|v| v.to_i(16)}.pack("C*")
        when :time      then cast_to_time(value)
        when :boolean   then self.class.value_to_boolean(value)
        else value
        end
      end
      
      def cast_to_date_or_time(value)
        return value if value.is_a? Date
        return nil if value.blank?
        guess_date_or_time (value.is_a? Time) ? value : cast_to_time(value)
      end

      def cast_to_time(value)
        return value if value.is_a? Time
        time_array = ParseDate.parsedate value
        time_array[0] ||= 2000; time_array[1] ||= 1; time_array[2] ||= 1;
        Time.send(ActiveRecord::Base.default_timezone, *time_array) rescue nil
      end

      def guess_date_or_time(value)
        (value.hour == 0 and value.min == 0 and value.sec == 0) ?
        Date.new(value.year, value.month, value.day) : value
      end

      def simplified_type(field_type)
        return :boolean if field_type =~ /smallint/i 
        return :float if field_type =~ /real/i
        super
      end
    end

    include JdbcSpec::MissingFunctionalityHelper
    
    def modify_types(tp)
      tp[:primary_key] = "int generated by default as identity NOT NULL PRIMARY KEY"
      tp[:integer][:limit] = nil
      tp[:string][:limit] = 256
      tp[:boolean] = {:name => "smallint"}
      tp
    end

    def add_limit_offset!(sql, options) # :nodoc:
      @limit = options[:limit]
      @offset = options[:offset]
    end
    
    def select_all(sql, name = nil)
      execute(sql, name)
    end
    
    def select_one(sql, name = nil)
      @limit ||= 1
      execute(sql, name).first
    ensure
      @limit = nil
    end
    
    def classes_for_table_name(table)
      ActiveRecord::Base.send(:subclasses).select {|klass| klass.table_name == table}
    end

    # Set the sequence to the max value of the table's column.
    def reset_sequence!(table, column, sequence = nil)
      mpk = select_value("SELECT MAX(#{quote_column_name column}) FROM #{table}")
      execute("ALTER TABLE #{table} ALTER COLUMN #{quote_column_name column} RESTART WITH #{mpk.to_i + 1}")      
    end
      
    def reset_pk_sequence!(table, pk = nil, sequence = nil)
      klasses = classes_for_table_name(table)
      klass   = klasses.nil? ? nil : klasses.first
      pk      = klass.primary_key unless klass.nil?
      if pk && klass.columns_hash[pk].type == :integer
        reset_sequence!(klass.table_name, pk)
      end
    end
    
    def _execute(sql, name = nil)
      log_no_bench(sql, name) do
        case sql.strip
        when /^(select|show)/i:
          @offset ||= 0
          if !@limit || @limit == -1
            range = @offset..-1
            max = 0
          else
            range = @offset...(@offset+@limit)
            max = @offset+@limit+1
          end
          @connection.execute_query(sql,max)[range] || []
        when /^insert/i:
          @connection.execute_insert(sql)
        else
          @connection.execute_update(sql)
        end
      end
    ensure
      @limit = @offset = nil
    end

    def primary_key(table_name) #:nodoc:
      primary_keys(table_name).first
    end

    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def rename_table(name, new_name)
      execute "RENAME TABLE #{name} TO #{new_name}"
    end
    
    COLUMN_INFO_STMT = "SELECT C.COLUMNNAME, C.REFERENCEID, C.COLUMNNUMBER FROM SYS.SYSCOLUMNS C, SYS.SYSTABLES T WHERE T.TABLEID = '%s' AND T.TABLEID = C.REFERENCEID ORDER BY C.COLUMNNUMBER"

    COLUMN_TYPE_STMT = "SELECT COLUMNDATATYPE, COLUMNDEFAULT FROM SYS.SYSCOLUMNS WHERE REFERENCEID = '%s' AND COLUMNNAME = '%s'"

    AUTO_INC_STMT = "SELECT AUTOINCREMENTSTART, AUTOINCREMENTINC, COLUMNNAME, REFERENCEID, COLUMNDEFAULT FROM SYS.SYSCOLUMNS WHERE REFERENCEID = '%s' AND COLUMNNAME = '%s'"


    def add_quotes(name)
      return name unless name
      %Q{"#{name}"}
    end
    
    def strip_quotes(str)
      return str unless str
      return str unless /^(["']).*\1$/ =~ str
      str[1..-2]
    end

    def expand_double_quotes(name)
      return name unless name && name['"']
      name.gsub(/"/,'""')
    end
    
    def reinstate_auto_increment(name, refid, coldef)
      stmt = AUTO_INC_STMT % [refid, strip_quotes(name)]
      data = execute(stmt).first
      if data
        start = data['autoincrementstart']
        if start
          coldef << " GENERATED " << (data['columndefault'].nil? ? "ALWAYS" : "BY DEFAULT ")
          coldef << "AS IDENTITY (START WITH "
          coldef << start
          coldef << ", INCREMENT BY "
          coldef << data['autoincrementinc']
          coldef << ")"
          return true
        end
      end
      false
    end
    
    def create_column(name, refid, colno)
      stmt = COLUMN_TYPE_STMT % [refid, strip_quotes(name)]
      coldef = ""
      data = execute(stmt).first
      if data
        coldef << add_quotes(expand_double_quotes(strip_quotes(name)))
        coldef << " "
        coldef << data['columndatatype']
        if !reinstate_auto_increment(name, refid, coldef) && data['columndefault']
          coldef << " DEFAULT " << data['columndefault']
        end
      end
      coldef
    end
    
    def structure_dump #:nodoc:
      data = ""
      execute("select tablename, tableid from sys.systables where schemaid not in (select schemaid from sys.sysschemas where schemaname LIKE 'SYS%')").each do |tbl|
        tid = tbl["tableid"]
        tname = tbl["tablename"]
        data << "CREATE TABLE #{tname} (\n"
        first_col = true
        execute(COLUMN_INFO_STMT % tid).each do |col|
          col_name = add_quotes(col['columnname']);
          create_col_string = create_column(col_name, col['referenceid'],col['columnnumber'].to_i)
          if !first_col
            create_col_string = ",\n #{create_col_string}"
          else
            create_col_string = " #{create_col_string}"
          end

          data << create_col_string

          first_col = false
        end
        data << ");\n\n"
      end
      data
    end
    
    # Support for removing columns added via derby bug issue:
    # https://issues.apache.org/jira/browse/DERBY-1489
    #
    # This feature has not made it into a formal release and is not in Java 6.  We will
    # need to conditionally support this somehow (supposed to arrive for 10.3.0.0)
    def remove_column(table_name, column_name)
      begin
        execute "ALTER TABLE #{table_name} DROP COLUMN #{column_name} RESTRICT"
      rescue
        alter_table(table_name) do |definition|
          definition.columns.delete(definition[column_name])
        end
#        raise NotImplementedError, "remove_column is not support on this Derby version"
      end
    end
    
    # Notes about changing in Derby:
    #    http://db.apache.org/derby/docs/10.2/ref/rrefsqlj81859.html#rrefsqlj81859__rrefsqlj37860)
    # Derby cannot: Change the column type or decrease the precision of an existing type, but
    #   can increase the types precision only if it is a VARCHAR.
    #
    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      # Derby can't change the datatype or size unless the type is varchar
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DATA TYPE #{type_to_sql(type, options[:limit])}" if type == :string
      if options.include? :null
        # This seems to only work with 10.2 of Derby
        if options[:null] == false
          execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} NOT NULL"
        else
          execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} NULL"
        end
      end
    end

    # There seems to be more than one thing wrong with 
    # changing defaults for VARCHAR columns right now... DERBY-2371
    # among others
    def change_column_default(table_name, column_name, default) #:nodoc:
      begin
        execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} DEFAULT #{quote(default)}"
      rescue
        alter_table(table_name) do |definition|
          definition[column_name].default = default
        end
      end        
    end

    # Support for renaming columns:
    # https://issues.apache.org/jira/browse/DERBY-1490
    #
    # This feature is expect to arrive in version 10.3.0.0:
    # http://wiki.apache.org/db-derby/DerbyTenThreeRelease)
    #
    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      begin
        execute "ALTER TABLE #{table_name} ALTER RENAME COLUMN #{column_name} TO #{new_column_name}"
      rescue
        alter_table(table_name, :rename => {column_name => new_column_name})
      end
    end
    
    def primary_keys(table_name)
      @connection.primary_keys table_name.to_s.upcase
    end

    def recreate_database(db_name)
      tables.each do |t|
        drop_table t
      end
    end
    
    def tables
      super.reject{|t| t =~ /^sys/ }
    end
    
    # For migrations, exclude the primary key index as recommended
    # by the HSQLDB docs.  This is not a great test for primary key
    # index.
    def indexes(table_name)
      @connection.indexes(table_name)
    end
    
    def quote(value, column = nil) # :nodoc:
      return value.to_s if column && column.type == :primary_key

      case value
      when String
        if column 
          case column.type
          when :binary
            "CAST(x'#{quote_string(value).unpack("C*").collect {|v| v.to_s(16)}.join}' AS BLOB)"
          when :string
            "'#{quote_string(value)}'"
          else
            vi = value.to_i
            if vi.to_s == value
              value
            else
              "'#{quote_string(value)}'"
            end
          end
        else
          super
        end
      else super
      end
    end

    def quote_string(s)
      s.gsub(/'/, "''") # ' (for ruby-mode)
    end
    
# For DDL it appears you can quote "" column names, but in queries (like insert it errors out?)
    def quote_column_name(name) #:nodoc:
      if /^references$/i =~ name
        %Q{"#{name.upcase}"}
      elsif /[A-Z]/ =~ name && /[a-z]/ =~ name
        %Q{"#{name}"}
      elsif name =~ /\s/
        %Q{"#{name.upcase}"}
      else
        name
      end
    end
    
    def quoted_true
      '1'
    end

    def quoted_false
      '0'
    end
  end
end

