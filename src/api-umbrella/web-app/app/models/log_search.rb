class LogSearch
  attr_accessor :query, :query_options
  attr_reader :client, :start_time, :end_time, :interval, :region, :country, :state

  CASE_SENSITIVE_FIELDS = [
    "api_key",
    "request_ip_country",
    "request_ip_region",
    "request_ip_city",
  ]

  def initialize(options = {})
    @client = Elasticsearch::Client.new({
      :hosts => ApiUmbrellaConfig[:elasticsearch][:hosts],
      :logger => Rails.logger
    })

    @start_time = options[:start_time]
    unless(@start_time.kind_of?(Time))
      @start_time = Time.zone.parse(@start_time)
    end

    @end_time = options[:end_time]
    unless(@end_time.kind_of?(Time))
      @end_time = Time.zone.parse(@end_time).end_of_day
    end

    if(@end_time > Time.zone.now)
      @end_time = Time.zone.now
    end

    @interval = options[:interval]
    @region = options[:region]

    @query = {
      :query => {
        :filtered => {
          :query => {
            :match_all => {},
          },
          :filter => {
            :bool => {
              :must => [],
              :must_not => [],
            },
          },
        },
      },
      :sort => [
        { :request_at => :desc },
      ],
      :aggregations => {},
    }

    @query_options = {
      :size => 0,
      :ignore_unavailable => "missing",
      :allow_no_indices => true,
    }
  end

  def result
    query_options = @query_options.merge({
      :index => indexes.join(","),
      :body => @query,
    })

    # Starting in ElasticSearch 1.4, we need to explicitly remove the
    # aggregations if there aren't actually any present for scroll queries to
    # work.
    if query_options[:body][:aggregations] && query_options[:body][:aggregations].blank?
      query_options[:body].delete(:aggregations)
    end

    raw_result = @client.search(query_options)

    @result = LogResult.new(self, raw_result)
  end

  def permission_scope!(scopes)
    filter = {
      :bool => {
        :should => []
      },
    }

    scopes.each do |scope|
      filter[:bool][:should] << scope
    end

    @query[:query][:filtered][:filter][:bool][:must] << filter
  end

  def search_type!(search_type)
    @query_options[:search_type] = search_type
  end

  def search!(query_string)
    if(query_string.present?)
      @query[:query][:filtered][:query] = {
        :query_string => {
          :query => query_string
        },
      }
    end
  end

  def query!(query)
    if(query.kind_of?(String) && query.present?)
      query = MultiJson.load(query)
    end

    if(query.present?)
      filters = []
      query["rules"].each do |rule|
        filter = {}

        if(!CASE_SENSITIVE_FIELDS.include?(rule["field"]) && rule["value"].kind_of?(String))
          rule["value"].downcase!
        end

        case(rule["operator"])
        when "equal", "not_equal"
          filter = {
            :term => {
              rule["field"] => rule["value"],
            },
          }
        when "begins_with", "not_begins_with"
          filter = {
            :prefix => {
              rule["field"] => rule["value"],
            },
          }
        when "contains", "not_contains"
          filter = {
            :regexp => {
              rule["field"] => ".*#{Regexp.escape(rule["value"])}.*",
            },
          }
        when "is_null", "is_not_null"
          filter = {
            :exists => {
              "field" => rule["field"],
            },
          }
        when "less"
          filter = {
            :range => {
              rule["field"] => {
                "lt" => rule["value"].to_f,
              },
            },
          }
        when "less_or_equal"
          filter = {
            :range => {
              rule["field"] => {
                "lte" => rule["value"].to_f,
              },
            },
          }
        when "greater"
          filter = {
            :range => {
              rule["field"] => {
                "gt" => rule["value"].to_f,
              },
            },
          }
        when "greater_or_equal"
          filter = {
            :range => {
              rule["field"] => {
                "gte" => rule["value"].to_f,
              },
            },
          }
        when "between"
          values = rule["value"].map { |v| v.to_f }.sort
          filter = {
            :range => {
              rule["field"] => {
                "gte" => values[0],
                "lte" => values[1],
              },
            },
          }
        else
          raise "unknown filter operator: #{rule["operator"]} (rule: #{rule.inspect})"
        end

        if(rule["operator"] =~ /(^not|^is_null)/ && filter.present?)
          filter = { :not => filter }
        end

        filters << filter
      end

      if(filters.present?)
        condition = if(query["condition"] == "OR") then :or else :and end
        filter = {
          condition => filters
        }

        @query[:query][:filtered][:filter][:bool][:must] << filter
      end
    end
  end

  def offset!(from)
    @query_options[:from] = from
  end

  def limit!(size)
    @query_options[:size] = size
  end

  def sort!(sort)
    @query[:sort] = sort
  end

  def exclude_imported!
    @query[:query][:filtered][:filter][:bool][:must_not] << {
      :exists => {
        :field => "imported",
      },
    }
  end

  def filter_by_date_range!
    @query[:query][:filtered][:filter][:bool][:must] << {
      :range => {
        :request_at => {
          :from => @start_time.iso8601,
          :to => @end_time.iso8601,
        },
      },
    }
  end

  def filter_by_request_path!(request_path)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :request_path => request_path,
      },
    }
  end

  def filter_by_api_key!(api_key)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :api_key => api_key,
      },
    }
  end

  def filter_by_user!(user_email)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => {
        :user => {
          :user_email => user_email,
        },
      },
    }
  end

  def filter_by_user_ids!(user_ids)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :terms => {
        :user_id => user_ids,
      },
    }
  end

  def aggregate_by_drilldown!(prefix, size = 0)
    @query[:aggregations][:drilldown] = {
      :terms => {
        :field => "request_hierarchy",
        :size => size,
        :include => "^#{Regexp.escape(prefix)}.*",
      },
    }
  end

  def aggregate_by_drilldown_over_time!(prefix)
    @query[:query][:filtered][:filter][:bool][:must] <<                 {
      :prefix => {
        :request_hierarchy => prefix,
      },
    }

    @query[:aggregations][:top_path_hits_over_time] = {
      :terms => {
        :field => "request_hierarchy",
        :size => 10,
        :include => "^#{Regexp.escape(prefix)}.*",
      },
      :aggregations => {
        :drilldown_over_time => {
          :date_histogram => {
            :field => "request_at",
            :interval => @interval,
            :time_zone => Time.zone.name,
            :pre_zone_adjust_large_interval => true,
            :min_doc_count => 0,
            :extended_bounds => {
              :min => @start_time.iso8601,
              :max => @end_time.iso8601,
            },
          },
        },
      },
    }

    @query[:aggregations][:hits_over_time] = {
      :date_histogram => {
        :field => "request_at",
        :interval => @interval,
        :time_zone => Time.zone.name,
        :pre_zone_adjust_large_interval => true,
        :min_doc_count => 0,
        :extended_bounds => {
          :min => @start_time.iso8601,
          :max => @end_time.iso8601,
        },
      },
    }
  end

  def aggregate_by_interval!
    @query[:aggregations][:hits_over_time] = {
      :date_histogram => {
        :field => "request_at",
        :interval => @interval,
        :time_zone => Time.zone.name,
        :pre_zone_adjust_large_interval => true,
        :min_doc_count => 0,
        :extended_bounds => {
          :min => @start_time.iso8601,
          :max => @end_time.iso8601,
        },
      },
    }
  end

  def aggregate_by_region!
    case(@region)
    when "world"
      aggregate_by_country!
    when "US"
      @country = @region
      aggregate_by_country_regions!(@region)
    when /^(US)-([A-Z]{2})$/
      @country = Regexp.last_match[1]
      @state = Regexp.last_match[2]
      aggregate_by_us_state_cities!(@country, @state)
    else
      @country = @region
      aggregate_by_country_cities!(@region)
    end
  end

  def aggregate_by_region_field!(field)
    @query[:aggregations][:regions] = {
      :terms => {
        :field => field.to_s,
        :size => 500,
      },
    }

    @query[:aggregations][:missing_regions] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_country!
    aggregate_by_region_field!(:request_ip_country)
  end

  def aggregate_by_country_regions!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_region)
  end

  def aggregate_by_us_state_cities!(country, state)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_region => state },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_country_cities!(country)
    @query[:query][:filtered][:filter][:bool][:must] << {
      :term => { :request_ip_country => country },
    }

    aggregate_by_region_field!(:request_ip_city)
  end

  def aggregate_by_term!(field, size)
    @query[:aggregations]["top_#{field.to_s.pluralize}"] = {
      :terms => {
        :field => field.to_s,
        :size => size,
        :shard_size => size * 4,
      },
    }

    @query[:aggregations]["value_count_#{field.to_s.pluralize}"] = {
      :value_count => {
        :field => field.to_s,
      },
    }

    @query[:aggregations]["missing_#{field.to_s.pluralize}"] = {
      :missing => {
        :field => field.to_s,
      },
    }
  end

  def aggregate_by_cardinality!(field)
    @query[:aggregations]["unique_#{field.to_s.pluralize}"] = {
      :cardinality => {
        :field => field.to_s,
        :precision_threshold => 100,
      },
    }
  end

  def aggregate_by_users!(size)
    aggregate_by_term!(:user_email, size)
    aggregate_by_cardinality!(:user_email)
  end

  def aggregate_by_request_ip!(size)
    aggregate_by_term!(:request_ip, size)
    aggregate_by_cardinality!(:request_ip)
  end

  def aggregate_by_user_stats!(options = {})
    @query[:aggregations][:user_stats] = {
      :terms => {
        :field => :user_id,
        :size => 0,
      }.merge(options),
      :aggregations => {
        :last_request_at => {
          :max => {
            :field => :request_at,
          },
        },
      },
    }
  end

  def aggregate_by_response_time_average!
    @query[:aggregations][:response_time_average] = {
      :avg => {
        :field => :response_time,
      },
    }
  end

  private

  def indexes
    unless @indexes
      date_range = @start_time.utc.to_date..@end_time.utc.to_date
      @indexes = date_range.map { |date| "api-umbrella-logs-#{date.strftime("%Y-%m")}" }
      @indexes.uniq!
    end

    @indexes
  end
end
