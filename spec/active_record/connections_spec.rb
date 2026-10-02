require 'bundler/setup'
require 'rspec'
require 'fileutils'
require 'active_record'
require 'active_record/connections'
require 'support/customer'
require 'support/contact'
require 'support/hotel'

describe ActiveRecord::Connections do
  let :migrations_path do
    File.expand_path('../../db/migrate', __FILE__)
  end

  before do
    ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => ':memory:')
    OtherDB.establish_connection(:adapter => 'sqlite3', :database => ':memory:')

    ActiveRecord::Migration.verbose = false
    ActiveRecord::Migrator.migrate(migrations_path)

    @customer_1 = Customer.create!(:name => 'Customer 1')
    @customer_2 = Customer.create!(:name => 'Customer 2')
    @customer_3 = Customer.create!(:name => 'Customer 3')

    Customer.each do
      ActiveRecord::Migrator.migrate(migrations_path)
    end

    # ActiveRecord:Migrator has ActiveRecord::Base hardcoded
    # and use that to get the connection so we will migrate manually
    OtherDB.connection.execute("
      CREATE TABLE hotels(id int primary key,name text)
    ")

    Customer.each do |customer|
      Contact.create!(:name => "Gabriel Sobrinho")
    end
  end

  after do
    Customer.each do
      Contact.destroy_all
    end

    Customer.destroy_all
  end

  it 'use proxy connection for count' do
    Customer.each do |customer|
      Contact.count.should eq 1
    end
  end

  it 'use proxy connection for create' do
    Customer.each do |customer|
      Contact.first.should be
    end
  end

  it 'use proxy connection for update' do
    Customer.each do |customer|
      Contact.update_all(:name => customer.name)
    end

    Customer.each do |customer|
      Contact.first.name.should eq customer.name
    end
  end

  it 'use proxy connection for destroy' do
    Customer.each do
      Contact.destroy_all
    end

    Customer.each do |customer|
      Contact.count.should eq 0
    end
  end

  it 'allows nested proxy connections' do
    @customer_1.using_connection do
      @customer_2.using_connection do
        @customer_3.using_connection do
          Contact.update_all(:name => @customer_3.name)
        end

        Contact.update_all(:name => @customer_2.name)
      end

      Contact.update_all(:name => @customer_1.name)
    end

    Customer.each do |customer|
      Contact.first.name.should eq customer.name
    end
  end

  it 'fabricates the connection class only once under concurrent first access' do
    fabrications = Queue.new

    probe = Module.new do
      define_method(:fabricate_connection_klass) do
        fabrications << 1
        ::Kernel.sleep 0.05
        super()
      end
    end
    ActiveRecord::Connections::ConnectionProxy.send(:prepend, probe)

    threads = 8.times.map do
      Thread.new do
        ActiveRecord::Base.using_connection(999_999, :adapter => 'sqlite3', :database => ':memory:') do
          ActiveRecord::Base.proxy_connection.respond_to?(:execute)
        end
      end
    end
    threads.each(&:join)

    fabrications.size.should eq 1
  end

  it 'do not propagate proxy connection between threads (thread-safe)' do
    Thread.new do
      ActiveRecord::Base.proxy_connection = 'proxy connection from another thread'
    end.join

    ActiveRecord::Base.proxy_connection.should be_nil
  end

  # These specs run on an in-memory SQLite database, where closing the
  # connection would wipe the data -- so here we only observe the checkin.
  # Actually closing idle connections is covered by the file-backed specs below.
  it 'releases the connection when leaving the block' do
    pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      "ActiveRecord::Connections::AbstractConnection#{@customer_1.id}"
    )

    @customer_1.using_connection do
      Contact.count
    end

    pool.should_not be_active_connection
  end

  it 'keeps the connection while an outer block is still using it' do
    pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
      "ActiveRecord::Connections::AbstractConnection#{@customer_1.id}"
    )

    @customer_1.using_connection do
      @customer_1.using_connection do
        Contact.count
      end

      # The inner block is done, but the outer one still uses the same connection
      pool.should be_active_connection
      Contact.count.should eq 1
    end

    pool.should_not be_active_connection
  end

  context 'on a file-backed database' do
    let :database_path do
      File.expand_path('../../../tmp/release_connection_spec.sqlite3', __FILE__)
    end

    let :pool do
      ActiveRecord::Base.connection_handler.retrieve_connection_pool(
        'ActiveRecord::Connections::AbstractConnection42'
      )
    end

    before do
      FileUtils.mkdir_p(File.dirname(database_path))

      ActiveRecord::Base.using_connection(42, :adapter => 'sqlite3', :database => database_path) do
        ActiveRecord::Base.connection.execute('SELECT 1')
      end
    end

    after do
      FileUtils.rm_f(database_path)
    end

    it 'closes idle connections when leaving the block' do
      pool.connections.should be_empty
    end

    it 'reconnects transparently on the next block' do
      ActiveRecord::Base.using_connection(42, :adapter => 'sqlite3', :database => database_path) do
        ActiveRecord::Base.connection.select_value('SELECT 42').should eq 42
      end
    end

    context 'when close_idle_on_release is disabled' do
      before { ActiveRecord::Connections.close_idle_on_release = false }
      after { ActiveRecord::Connections.close_idle_on_release = true }

      it 'only checks the connection back into the pool, keeping the socket open' do
        ActiveRecord::Base.using_connection(42, :adapter => 'sqlite3', :database => database_path) do
          ActiveRecord::Base.connection.execute('SELECT 1')
        end

        pool.connections.size.should eq 1
        pool.should_not be_active_connection
      end
    end
  end

  it 'tracks connection depth per thread' do
    depths = nil

    ActiveRecord::Base.using_connection(@customer_1.id, @customer_1.database_spec) do
      # The child thread does not see the depth tracked by the parent thread
      Thread.new do
        depths = ActiveRecord::Base.connection_depths.dup
      end.join

      ActiveRecord::Base.connection_depths[@customer_1.id].should eq 1
    end

    depths.should eq({})
    ActiveRecord::Base.connection_depths.should eq({})
  end

  it 'should have seperate dbs for contacts and hotels' do
    # Framework tables vary across Rails versions (ar_internal_metadata only
    # exists on 5+), so compare just the tables this suite creates.
    internal = %w[schema_migrations ar_internal_metadata]

    Customer.each do |customer|
      (Contact.connection.tables - internal).should eq %w[customers contacts]
      # only one table created manually
      (Hotel.connection.tables - internal).should eq %w[hotels]
    end
  end
end
