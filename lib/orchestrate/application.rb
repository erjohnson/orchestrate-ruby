module Orchestrate

  # Applications in Orchestrate are the highest level of your project.
  class Application

    # @return [String] The API key provided
    attr_reader :api_key

    # @return [Orchestrate::Client] The client tied to this application.
    attr_reader :client

    # Instantiate a new Application
    # @param client_or_api_key [Orchestrate::Client, #to_s] A client instantiated with the API key and faraday setup, or the API key for your Orchestrate Application.
    # @yieldparam [Faraday::Connection] connection Setup for the Faraday connection.
    # @return Orchestrate::Application
    def initialize(client_or_api_key, &client_setup)
      if client_or_api_key.kind_of?(Orchestrate::Client)
        @client = client_or_api_key
        @api_key = client.api_key
      else
        @api_key = client_or_api_key
        @client = Client.new(api_key, &client_setup)
      end
      client.ping
    end

    # Accessor for Collections
    # @param collection_name [#to_s] The name of the collection.
    # @return Orchestrate::Collection
    def [](collection_name)
      Collection.new(self, collection_name)
    end

    # Performs requests in parallel.  Requires using a Faraday adapter that supports parallel requests.
    # @yieldparam accumulator [Hash] A place to store the results of the parallel responses.
    # @example Performing three requests at once
    #   responses = app.in_parallel do |r|
    #     r[:some_items] = app[:site_globals].lazy
    #     r[:user]       = app[:users][current_user_key]
    #     r[:user_feed]  = app.client.list_events(:users, current_user_key, :notices)
    #   end
    # @see README See the Readme for more examples.
    def in_parallel(&block)
      old_client = client
      client.in_parallel do |parallel_client, accumulator|
        @client = parallel_client
        # the block provided to #in_parallel -should- return right away.
        block.call(accumulator)
        @client = old_client
        # client.in_parallel will return when it's done.
      end
    end

    # @return a pretty-printed representation of the application.
    def to_s
      "#<Orchestrate::Application api_key=#{api_key[0..7]}...>"
    end
    alias :inspect :to_s

  end
end
