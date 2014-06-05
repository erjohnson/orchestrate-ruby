require 'faraday'
require 'faraday_middleware'

module Orchestrate

  # ==== Ruby Client for the Orchestrate REST *API*.
  #
  # The primary entry point is the #send_request method, which generates a
  # Request, and returns the Response to the caller.
  #
  class Client

    # Orchestrate::Configuration instance for the client.  If not explicitly
    # provided during initialization, will default to Orchestrate.config
    attr_accessor :config

    # The Faraday HTTP "connection" for the client.
    attr_accessor :http

    # Initialize and return a new Client instance. Optionally, configure
    # options for the instance by passing a Configuration object. If no
    # custom configuration is provided, the configuration options from
    # Orchestrate.config will be used.
    def initialize(config = Orchestrate.config)
      @config = config

      @http = Faraday.new(config.base_url) do |faraday|
        if config.faraday.respond_to?(:call)
          config.faraday.call(faraday)
        else
          faraday.adapter Faraday.default_adapter
        end

        # faraday seems to want you do specify these twice.
        faraday.request :basic_auth, config.api_key, ''
        faraday.basic_auth config.api_key, ''

        # parses JSON responses
        faraday.response :json, :content_type => /\bjson$/
      end
    end

    def ping
      send_request :get, []
    end

    # -------------------------------------------------------------------------
    #  collection

    # call-seq:
    #   client.list(collection_name, parameters = {})   -> response
    #
    # Performes a List query against the given collection.  Results are sorted
    # lexicographically by key name.
    #
    # +collection_name+:: A String or Symbol representing the name of the collection.
    # +parameters+:: a Hash object containing query parameters:
    # - +:limit+   - integer, number of results to return.  Defaults to 10, Max 100.
    # - +:start+   - string, start key of query range, including value.
    # - +:after+   - string, start key of query range, excluding value.
    # - +:before+  - string, end key of query range, excluding value.
    # - +:end+     - string, end key of query range, including value.
    #
    # Note, you cannot provide *both* 'start' and 'after', or 'before' and 'end'
    #
    def list(collection, options={})
      Orchestrate::Helpers.range_keys!('key', options)
      resp = send_request :get, [collection], { query: options }
      API::CollectionResponse.new(resp)
    end

    # call-seq:
    #   client.list(collection_name, query, parameters = {})  -> response
    #
    # Performs a Search query against the given collection.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +query+:: a String containing a Lucene query
    # +parameters+:: a Hash object containing additional parameters:
    # - +limit+:  - integer, number of results to return.  Defaults to 10, Max 100.
    # - +offset+: - ingeger, the starting position of the results.  Defaults to 0.
    #
    def search(collection, query, parameters={})
      resp = send_request :get, [collection], { query: parameters.merge({query: query})}
      API::CollectionResponse.new(resp)
    end

    # Notes:
    # will return 204 No Content regardless of if collection exists or not,
    # provided all other conditions are met.

    # call-seq:
    #   client.delete_collection(collection_name) -> response
    #
    # Deletes the given collection.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    #
    def delete_collection(collection)
      resp = send_request :delete, [collection], { query: {force:true} }
      API::Response.new(resp)
    end

    #  -------------------------------------------------------------------------
    #  Key/Value

    # call-seq:
    #   client.get(collection_name, key)              -> response
    #   client.get(collection_name, key, ref)         -> response
    #
    # Retreieves a value assigned to a key.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +ref+:: if given, returns the value for the key at the specified ref.  If omitted, returns the latest value for the key.
    #
    def get(collection, key, ref=nil)
      path = [collection, key]
      path.concat(['refs', ref]) if ref
      API::ItemResponse.new(send_request(:get, path))
    end

    # call-seq:
    #   client.get(collection_name, key)              -> response
    #   client.get(collection_name, key, parameters)  -> response
    #
    # Retrieves a list of refs for the specified key and collection.
    #
    # +collection_name+:: a String of Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +parameters+:: a Hash object containing additional parameters:
    # - +limit+:: integer, number of results to return.  Defaults to 10, Max 100.
    # - +offset+:: integer, starting position of the results.  Defaults to 0.
    # - +values+:: boolean, whether to return the values for each ref.
    #
    def list_refs(collection, key, parameters={})
      send_request :get, [collection, key, :refs], { query: parameters }
    end

    # call-seq:
    #   client.put(collection_name, key, body)            -> response
    #   client.put(collection_name, key, body, condition) -> response
    #
    # Creates or Updates the value at the specified key.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +body+:: a Hash object representing the value for the key.
    # +condition+::
    # - +nil+ - the value for the specified key will be updated regardless.
    # - String - used as 'If-Match'.  The value will only be updated if the Key's current Value's Ref matches the given condition.
    # - false - used as 'If-None-Match'.  The value will only be created for the key if the key currently has no value.
    #
    def put(collection, key, body, condition=nil)
      headers={}
      if condition.is_a?(String)
        headers['If-Match'] = format_ref(condition)
      elsif condition == false
        headers['If-None-Match'] = '*'
      end
      resp = send_request :put, [collection, key], { body: body, headers: headers }
      API::ItemResponse.new(resp)
    end
    alias :put_if_unmodified :put

    #  call-seq:
    #     client.put_if_absent(collection_name, key, body)    -> response
    #
    # Will create the value at the specified key only if there is no existing value for the specified key.
    #
    def put_if_absent(collection, key, body)
      put collection, key, body, false
    end

    # call-seq:
    #   client.delete(collection_name, key)      -> response
    #   client.delete(collection_name, key, ref) -> response
    #
    # Deletes the value of the specified key.  Historical values for given refs are still available.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +ref+:: if provided, used as 'If-Match', will only delete the key if the current value is the provided ref.
    #
    def delete(collection, key, ref=nil)
      headers = {}
      headers['If-Match'] = format_ref(ref) if ref
      resp = send_request :delete, [collection, key], { headers: headers }
      API::Response.new(resp)
    end

    # call-seq:
    #   client.purge(collection_name, key) -> response
    #
    # Deletes the value for the specified key as well as all historical values.  Cannot be undone.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    #
    def purge(collection, key)
      resp = send_request :delete, [collection, key], { query: { purge: true } }
      API::Response.new(resp)
    end

    # -------------------------------------------------------------------------
    #  Events

    # call-seq:
    #   client.get_event(collection_name, key, event_type, timestamp, ordinal) -> response
    #
    # Gets the event for the specified arguments.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +event_type+:: a String or Symbol representing the category for the event.
    # +timestamp+:: a Time or Date, or an Integer or String representing a time.
    # - Time, or class that responds positively to #kind_of?(Time) and #to_f returns a float
    # - Date, or class that responds positively to #kind_of?(Date) (including DateTime) and implements #to_time, returning a Time
    # - Integers are Milliseconds since Unix Epoch.
    # - Strings must be formatted as per http://orchestrate.io/docs/api/#events/timestamps
    # +ordinal+:: an Integer representing the order of the event for this timestamp.
    #
    def get_event(collection, key, event_type, timestamp, ordinal)
      timestamp = Helpers.timestamp(timestamp)
      resp = send_request :get, [collection, key, 'events', event_type, timestamp, ordinal]
      API::ItemResponse.new(resp)
    end

    # call-seq:
    #   client.post_event(collection_name, key, event_type) -> response
    #   client.post_event(collection_name, key, event_type, timestamp) -> response
    #
    # Creates an event.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +event_type+:: a String or Symbol representing the category for the event.
    # +body+:: a Hash object representing the value for the event.
    # +timestamp+:: a Time or Date, or an Integer or String representing a time.
    # - nil - Timestamp value will be created by Orchestrate.
    # - Time, or class that responds positively to #kind_of?(Time) and #to_f returns a float
    # - Date, or class that responds positively to #kind_of?(Date) (including DateTime) and implements #to_time, returning a Time
    # - Integers are Milliseconds since Unix Epoch.
    # - Strings must be formatted as per http://orchestrate.io/docs/api/#events/timestamps
    #
    def post_event(collection, key, event_type, body, timestamp=nil)
      timestamp = Helpers.timestamp(timestamp)
      path = [collection, key, 'events', event_type, timestamp].compact
      resp = send_request :post, path, { body: body }
      API::ItemResponse.new(resp)
    end

    # call-seq:
    #   client.put_event(collection_name, key, event_type, timestamp, ordinal, body) -> response
    #   client.put_event(collection_name, key, event_type, timestamp, ordinal, body, ref) -> response
    #
    # Puts the event for the specified arguments.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +event_type+:: a String or Symbol representing the category for the event.
    # +timestamp+:: a Time or Date, or an Integer or String representing a time.
    # - Time, or class that responds positively to #kind_of?(Time) and #to_f returns a float
    # - Date, or class that responds positively to #kind_of?(Date) (including DateTime) and implements #to_time, returning a Time
    # - Integers are Milliseconds since Unix Epoch.
    # - Strings must be formatted as per http://orchestrate.io/docs/api/#events/timestamps
    # +ordinal+:: an Integer representing the order of the event for this timestamp.
    # +body+:: a Hash object representing the value for the event.
    # +ref+::
    # - +nil+ - The event will update regardless.
    # - String - used as 'If-Match'.  The event will only update if the event's current value matches this ref.
    #
    def put_event(collection, key, event_type, timestamp, ordinal, body, ref=nil)
      timestamp = Helpers.timestamp(timestamp)
      path = [collection, key, 'events', event_type, timestamp, ordinal]
      headers = {}
      headers['If-Match'] = format_ref(ref) if ref
      resp = send_request :put, path, { body: body, headers: headers }
      API::ItemResponse.new(resp)
    end

    # call-seq:
    #   client.purge_event(collection, key, event_type, timestamp, ordinal) -> response
    #   client.purge_event(collection, key, event_type, timestamp, ordinal, ref) -> response
    #
    # Deletes the event for the specified arguments.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +event_type+:: a String or Symbol representing the category for the event.
    # +timestamp+:: a Time or Date, or an Integer or String representing a time.
    # - Time, or class that responds positively to #kind_of?(Time) and #to_f returns a float
    # - Date, or class that responds positively to #kind_of?(Date) (including DateTime) and implements #to_time, returning a Time
    # - Integers are Milliseconds since Unix Epoch.
    # - Strings must be formatted as per http://orchestrate.io/docs/api/#events/timestamps
    # +ordinal+:: an Integer representing the order of the event for this timestamp.
    # +ref+::
    # - +nil+ - The event will be deleted regardless.
    # - String - used as 'If-Match'.  The event will only be deleted if the event's current value matches this ref.
    #
    def purge_event(collection, key, event_type, timestamp, ordinal, ref=nil)
      timestamp = Helpers.timestamp(timestamp)
      path = [collection, key, 'events', event_type, timestamp, ordinal]
      headers = {}
      headers['If-Match'] = format_ref(ref) if ref
      resp = send_request :delete, path, { query: { purge: true }, headers: headers }
      API::Response.new(resp)
    end

    # call-seq:
    #   client.list_events(collection_name, key, event_type) -> response
    #   client.list_events(collection_name, key, event_type, parameters = {}) -> response
    #
    # Puts the event for the specified arguments.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +event_type+:: a String or Symbol representing the category for the event.
    # +parameters+::
    # - +:limit+   - integer, number of results to return.  Defaults to 10, Max 100.
    # - +:start+   - Integer/String representing the inclusive start to a range.
    # - +:after+   - Integer/String representing the exclusive start to a range.
    # - +:before+  - Integer/String representing the exclusive end to a range.
    # - +:end+     - Integer/String representing the inclusive end to a range.
    #
    # Range parameters are formatted as ":timestamp/:ordinal", where "/ordinal" is optional.
    #
    # +timestamp+:: a Time or Date, or an Integer or String representing a time.
    # - Time, or class that responds positively to #kind_of?(Time) and #to_f returns a float
    # - Date, or class that responds positively to #kind_of?(Date) (including DateTime) and implements #to_time, returning a Time
    # - Integers are Milliseconds since Unix Epoch.
    # - Strings must be formatted as per http://orchestrate.io/docs/api/#events/timestamps
    #
    # +ordinal+:: optional; an Integer representing the order of the event for this timestamp.
    #
    def list_events(collection, key, event_type, parameters={})
      (parameters.keys & [:start, :after, :before, :end]).each do |param|
        parameters[param] = Helpers.timestamp(parameters[param])
      end
      Orchestrate::Helpers.range_keys!('event', parameters)
      send_request :get, [collection, key, 'events', event_type], { query: parameters }
    end

    # -------------------------------------------------------------------------
    #  Graph

    # call-seq:
    #   client.get_relations(collection_name, key, *kinds) -> response
    #
    # Returns the relation's collection, key and ref values.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +kinds+:: one or more String or Symbol values representing the relations and depth to walk.
    #
    def get_relations(collection, key, *kinds)
      path = [collection, key, 'relations'].concat(kinds)
      send_request :get, path
    end

    # call-seq:
    #   client.put_relation(collection_name, key, kind, to_collection_name, to_key) -> response
    #
    # Stores a relationship between two Key/Value items.  They do not need to be in the same collection.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +kind+:: a String or Symbol value representing the relation type.
    # +to_collection_name+:: a String or Symbol representing the name of the collection the related item belongs.
    # +to_key+:: a String or Symbol representing the key for the related item.
    #
    def put_relation(collection, key, kind, to_collection, to_key)
      resp = send_request :put, [collection, key, 'relation', kind, to_collection, to_key]
      API::Response.new(resp)
    end

    # call-seq:
    #   client.delete_relation(collection_name, key, kind, to_collection, to_key) -> response
    #
    # Deletes a relationship between two Key/Value items.
    #
    # +collection_name+:: a String or Symbol representing the name of the collection.
    # +key+:: a String or Symbol representing the key for the value.
    # +kind+:: a String or Symbol value representing the relation type.
    # +to_collection_name+:: a String or Symbol representing the name of the collection the related item belongs.
    # +to_key+:: a String or Symbol representing the key for the related item.
    #
    def delete_relation(collection, key, kind, to_collection, to_key)
      path = [collection, key, 'relation', kind, to_collection, to_key]
      resp = send_request :delete, path, { query: {purge: true} }
      API::Response.new(resp)
    end

    # call-seq:
    #   client.in_parallel {|responses| block } -> Hash
    #
    # Performs any requests generated inside the block in parallel.  If the
    # client isn't using a Faraday adapter that supports parallelization, will
    # output a warning to STDERR.
    #
    # Example:
    #   responses = client.in_parallel do |r|
    #     r[:some_items] = client.list(:site_globals)
    #     r[:user] = client.get(:users, current_user_key)
    #     r[:user_feed] = client.list_events(:users, current_user_key, :notices)
    #   end
    #
    def in_parallel(&block)
      accumulator = {}
      http.in_parallel do
        block.call(accumulator)
      end
      accumulator
    end

    # call-seq:
    #   client.send_request(method, url, opts={}) -> response
    #
    # Performs the HTTP request against the API and returns a Faraday::Response
    #
    # +method+ - the HTTP method, one of [ :get, :post, :put, :delete ]
    # +url+ - an Array of segments to be joined with '/'
    # +opts+
    # - +:query+ - a Hash for the request query string
    # - +:body+ - a Hash for the :put or :post request body
    # - +:headers+ - a Hash the request headers
    #
    def send_request(method, url, opts={})
      url = ['/v0'].concat(url).join('/')
      query_string = opts.fetch(:query, {})
      body = opts.fetch(:body, '')
      headers = opts.fetch(:headers, {})
      headers['User-Agent'] = "ruby/orchestrate/#{Orchestrate::VERSION}"
      headers['Accept'] = 'application/json' if method == :get

      response = http.send(method) do |request|
        request.url url, query_string
        if [:put, :post].include?(method)
          headers['Content-Type'] = 'application/json'
          request.body = body.to_json
        end
        headers.each {|header, value| request[header] = value }
      end

      Error.handle_response(response) if (!response.success?)
      response
    end

    # ------------------------------------------------------------------------

    private

      # Formats the provided 'ref' to be quoted per API specification.  If
      # already quoted, does not add additional quotes.
      def format_ref(ref)
        "\"#{ref.gsub(/"/,'')}\""
      end

  end

end
