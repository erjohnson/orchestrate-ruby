require 'faraday'
require 'faraday_middleware'

module Orchestrate

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

    # Sends a 'Ping' request to the API to test authentication:
    # http://orchestrate.io/docs/api/#authentication/ping
    # @return Orchestrate::API::Response
    # @raise Orchestrate::Error::Unauthorized if the client could not authenticate.
    def ping
      send_request :get, []
    end

    # -------------------------------------------------------------------------
    #  collection

    # Performs a [Key/Value List query](http://orchestrate.io/docs/api/#key/value/list) against the collection.
    # Orchestrate sorts results lexicographically by key name.
    # @param collection [#to_s] The name of the collection
    # @param options [Hash] Parameters for the query
    # @option options [Integer] :limit (10) The number of results to return. Maximum 100.
    # @option options [String] :start The inclusive start key of the query range.
    # @option options [String] :after The exclusive start key of the query range.
    # @option options [String] :before The exclusive end key of the query range.
    # @option options [String] :end The inclusive end key of the query range.
    # @note The Orchestrate API may return an error if you include both the
    #   :start/:after or :before/:end keys.  The client will not stop you from doing this.
    # @note To include all keys in a collection, do not include any :start/:after/:before/:end parameters.
    # @return Orchestrate::API::CollectionResponse
    # @raise Orchestrate::API::InvalidSearchParam The :limit value is not valid.
    def list(collection, options={})
      Orchestrate::Helpers.range_keys!('key', options)
      send_request :get, [collection], { query: options, response: API::CollectionResponse }
    end

    # Performs a [Search query](http://orchestrate.io/docs/api/#search) against the collection.
    # @param collection [#to_s] The name of the collection
    # @param query [String] The [Lucene Query String][lucene] to query the collection with.
    #   [lucene]: http://lucene.apache.org/core/4_3_0/queryparser/org/apache/lucene/queryparser/classic/package-summary.html#Overview
    # @param options [Hash] Parameters for the query
    # @option options [Integer] :limit (10) The number of results to return. Maximum 100.
    # @option options [Integer] :offset (0) The starting position of the results.
    # @return Orchestrate::API::CollectionResponse
    # @raise Orchestrate::API::InvalidSearchParam The :limit/:offset values are not valid.
    # @raise Orchestrate::API::SearchQueryMalformed if query isn't a valid Lucene query.
    def search(collection, query, options={})
      send_request :get, [collection], { query: options.merge({query: query}),
                                         response: API::CollectionResponse }
    end

    # Performs a [Delete Collection request](http://orchestrate.io/docs/api/#collections/delete).
    # @param collection [#to_s] The name of the collection
    # @return Orchestrate::API::Response
    # @note The Orchestrate API will return succesfully regardless of if the collection exists or not.
    def delete_collection(collection)
      send_request :delete, [collection], { query: {force:true} }
    end

    #  -------------------------------------------------------------------------
    #  Key/Value

    # Returns a value assigned to a key.  If the `ref` is omitted, returns the latest value.
    # When a ref is provided, performs a [Refs Get query](http://orchestrate.io/docs/api/#refs/get14).
    # When the ref is omitted, performs a [Key/Value Get query](http://orchestrate.io/docs/api/#key/value/get).
    # @param collection [#to_s] The name of the collection.
    # @param key [#to_s] The name of the key.
    # @param ref [#to_s] The opaque version identifier of the ref to return.
    # @return Orchestrate::API::ItemResponse
    # @raise Orchestrate::Error::NotFound If the key or ref doesn't exist.
    # @raise Orchestrate::Error::MalformedRef If the ref provided is not a valid ref.
    def get(collection, key, ref=nil)
      path = [collection, key]
      path.concat(['refs', ref]) if ref
      send_request :get, path, { response: API::ItemResponse }
    end

    # Performs a [Refs List query](http://orchestrate.io/docs/api/#refs/list15).
    # Returns a paginated, time-ordered, newest-to-oldest list of refs
    # ("versions") of the object for the specified key in the collection.
    # @param collection [#to_s] The name of the collection.
    # @param key [#to_s] The name of the key.
    # @param options [Hash] Parameters for the query.
    # @option options [Integer] :limit (10) The number of results to return. Maximum 100.
    # @option options [Integer] :offset (0) The starting position of the results.
    # @option options [true, false] :values (false) Whether to return the value
    #   for each ref.  Refs with no content (for example, deleted with `#delete`) will not have
    #   a value, but marked with a `'tombstone' => true` key.
    # @return Orchestrate::API::CollectionResponse
    # @raise Orchestrate::Error::NotFound If there are no values for the provided key/collection.
    # @raise Orchestrate::API::InvalidSearchParam The :limit/:offset values are not valid.
    def list_refs(collection, key, options={})
      send_request :get, [collection, key, :refs], { query: options, response: API::CollectionResponse }
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

    # Performs a [Key/Value Put](http://orchestrate.io/docs/api/#key/value/put-\(create/update\)) request.
    # Creates or updates the value at the provided collection/key.
    # @param collection [#to_s] The name of the collection.
    # @param key [#to_s] The name of the key.
    # @param body [#to_json] The value for the key.
    # @param condition [String, false, nil] Conditions for setting the value. 
    #   If `String`, value used as `If-Match`, value will only be updated if key's current value's ref matches.
    #   If `false`, uses `If-None-Match` the value will only be set if there is no existent value for the key.
    #   If `nil` (default), value is set regardless.
    # @return Orchestrate::API::ItemResponse
    # @raise Orchestrate::Error::BadRequest the body is not valid JSON.
    # @raise Orchestrate::Error::IndexingConflict One of the value's keys
    #   contains a value of a different type than the schema that exists for
    #   the collection.
    # @see Orchestrate::Error::IndexingConflict
    # @raise Orchestrate::Error::VersionMismatch A ref was provided, but it does not match the ref for the current value.
    # @raise Orchestrate::Error::AlreadyPresent the `false` condition was given, but a value already exists for this collection/key combo.
    def put(collection, key, body, condition=nil)
      headers={}
      if condition.is_a?(String)
        headers['If-Match'] = format_ref(condition)
      elsif condition == false
        headers['If-None-Match'] = '*'
      end
      send_request :put, [collection, key], { body: body, headers: headers, response: API::ItemResponse }
    end
    # @!method put_if_unmodified(collection, key, body, condition)
    #   Performs a [Key/Value Put If-Match](http://orchestrate.io/docs/api/#key/value/put-\(create/update\)) request.
    #   (see #put)
    alias :put_if_unmodified :put

    # Performs a [Key/Value Put If-None-Match](http://orchestrate.io/docs/api/#key/value/put-\(create/update\)) request.
    # (see #put)
    def put_if_absent(collection, key, body)
      put collection, key, body, false
    end

    # Performs a [Key/Value delete](http://orchestrate.io/docs/api/#key/value/delete11) request.
    # @param collection [#to_s] The name of the collection.
    # @param key [#to_s] The name of the key.
    # @param ref [#to_s] The If-Match ref to delete.
    # @return Orchestrate::API::Response
    # @raise Orchestrate::Error::VersionMismatch if the provided ref is not the ref for the current value.
    # @note previous versions of the values at this key are still available via #list_refs and #get.
    def delete(collection, key, ref=nil)
      headers = {}
      headers['If-Match'] = format_ref(ref) if ref
      send_request :delete, [collection, key], { headers: headers }
    end

    # Performs a [Key/Value purge](http://orchestrate.io/docs/api/#key/value/delete11) request.
    # @param collection [#to_s] The name of the collection.
    # @param key [#to_s] The name of the key.
    # @return Orchestrate::API::Response
    def purge(collection, key)
      send_request :delete, [collection, key], { query: { purge: true } }
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
      path = [collection, key, 'events', event_type, timestamp, ordinal]
      send_request :get, path, { response: API::ItemResponse }
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
      send_request :post, path, { body: body, response: API::ItemResponse }
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
      send_request :put, path, { body: body, headers: headers, response: API::ItemResponse }
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
      send_request :delete, path, { query: { purge: true }, headers: headers }
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
      path = [collection, key, 'events', event_type]
      send_request :get, path, { query: parameters, response: API::CollectionResponse }
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
      send_request :get, path, {response: API::CollectionResponse}
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
      send_request :put, [collection, key, 'relation', kind, to_collection, to_key]
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
      send_request :delete, path, { query: {purge: true} }
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
    # Performs the HTTP request against the API and returns an API::Response
    #
    # +method+ - the HTTP method, one of [ :get, :post, :put, :delete ]
    # +url+ - an Array of segments to be joined with '/'
    # +opts+
    # - +:query+ - a Hash for the request query string
    # - +:body+ - a Hash for the :put or :post request body
    # - +:headers+ - a Hash the request headers
    # - +:response+ - a subclass of API::Response to instantiate
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
      response_class = opts.fetch(:response, API::Response)
      response_class.new(response, self)
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
