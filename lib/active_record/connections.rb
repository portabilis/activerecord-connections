require 'active_support'

module ActiveRecord
  module Connections
    autoload :ConnectionProxy, 'active_record/connections/connection_proxy'

    # Using on ApplicationController:
    #
    #   class ApplicationController < ActionController::Base
    #     before_filter :handle_customer
    #
    #     protected
    #
    #     def handle_customer(&block)
    #       customer = Customer.find_by_domain!(request.domain)
    #       ActiveRecord::Base.using_connection(customer.id, customer.connection_spec, &block)
    #     end
    #   end
    #
    # Using directly on models:
    #
    #   customer = Customer.first
    #
    #   ActiveRecord::Base.using_connection(customer.id, customer.connection_spec) do
    #     User.count # => 3
    #   end
    #
    def using_connection(connection_name, connection_spec)
      old_proxy_connection = proxy_connection
      self.proxy_connection = ConnectionProxy.new(connection_name, connection_spec)

      increment_connection_depth(connection_name)

      yield
    ensure
      self.proxy_connection = old_proxy_connection

      # Every tenant gets its own pool, which stays alive even after the block
      # is done. Applications iterating over many tenants in sequence pile up
      # idle connections until the server or the pooler runs out of them.
      #
      # We give the connection back on the way out, but only from the outermost
      # block for that tenant -- nested blocks are still using it.
      release_connection(connection_name) if decrement_connection_depth(connection_name).zero?
    end

    # Closes the connection this thread holds for +connection_name+.
    #
    # +release_connection+ only checks the connection back into the pool: the
    # socket stays open and keeps taking up a slot on the server and on the
    # pooler. Since a tenant pool tends to sit idle for a long time after the
    # block, we actually close it.
    #
    # Only idle connections are closed, so threads sharing the same pool are
    # left alone. +disconnect+/+disconnect!+ are not an option here because they
    # +steal!+ connections that are still in use by other threads.
    #
    # +flush+ is only available on Rails 5.2 and up; on older versions we close
    # the idle connections ourselves.
    def release_connection(connection_name)
      pool = connection_handler.retrieve_connection_pool(
        "ActiveRecord::Connections::AbstractConnection#{connection_name}"
      )
      return unless pool

      pool.release_connection

      # On in-memory databases the data lives inside the connection, so closing
      # it would wipe the database.
      return if in_memory_pool?(pool)

      if pool.respond_to?(:flush)
        pool.flush(-1)
      else
        disconnect_idle_connections(pool)
      end
    end

    def in_memory_pool?(pool)
      database = pool.spec.config[:database].to_s

      database == ':memory:' || database.include?('mode=memory')
    end

    def disconnect_idle_connections(pool)
      idle_connections = pool.synchronize do
        pool.connections.reject(&:in_use?).each do |conn|
          conn.lease
          pool.instance_variable_get(:@available).delete(conn)
          pool.connections.delete(conn)
        end
      end

      idle_connections.each(&:disconnect!)
    end

    def connection_depths
      Thread.current[connection_depths_thread_local_name] ||= Hash.new(0)
    end

    def increment_connection_depth(connection_name)
      connection_depths[connection_name] += 1
    end

    def decrement_connection_depth(connection_name)
      depths = connection_depths
      depth = depths[connection_name] -= 1
      depths.delete(connection_name) if depth <= 0

      depth
    end

    def connection_depths_thread_local_name
      "#{proxy_connection_thread_local_name}.depths"
    end

    def proxy_connection
      Thread.current[proxy_connection_thread_local_name]
    end

    def proxy_connection=(proxy_connection)
      Thread.current[proxy_connection_thread_local_name] = proxy_connection
    end

    def proxy_connection_thread_local_name
      cls = self
      while cls != ActiveRecord::Base
        cls = cls.superclass
      end
      "ActiveRecord::Connections.proxy_connection#{cls.name}"
    end
  end
end

ActiveSupport.on_load(:active_record) do
  extend ActiveRecord::Connections

  def self.connection_pool
    connection_handler.retrieve_connection_pool(proxy_connection.try(:name) || 'primary')
  end

  def self.retrieve_connection
    connection_handler.retrieve_connection(proxy_connection.try(:name) || 'primary')
  end
end
