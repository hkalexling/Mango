require "./spec_helper"

describe Storage do
  it "creates DB at given path" do
    with_storage do |_, path|
      File.exists?(path).should be_true
    end
  end

  it "deletes user" do
    with_storage &.delete_user "admin"
  end

  it "creates new user" do
    with_storage do |storage|
      storage.new_user "user", "123456", false
      storage.new_user "admin", "123456", true
    end
  end

  it "verifies username/password combination" do
    with_storage do |storage|
      user_token = storage.verify_user "user", "123456"
      admin_token = storage.verify_user "admin", "123456"
      user_token.should_not be_nil
      admin_token.should_not be_nil
      State.set "user_token", user_token
      State.set "admin_token", admin_token
    end
  end

  it "rejects duplicate username" do
    with_storage do |storage|
      expect_raises SQLite3::Exception,
        "UNIQUE constraint failed: users.username" do
        storage.new_user "admin", "123456", true
      end
    end
  end

  it "verifies token" do
    with_storage do |storage|
      user_token = State.get! "user_token"
      user = storage.verify_token user_token
      user.should eq "user"
    end
  end

  it "verfies admin token" do
    with_storage do |storage|
      admin_token = State.get! "admin_token"
      storage.verify_admin(admin_token).should be_true
    end
  end

  it "rejects non-admin token" do
    with_storage do |storage|
      user_token = State.get! "user_token"
      storage.verify_admin(user_token).should be_false
    end
  end

  it "updates user" do
    with_storage do |storage|
      storage.update_user "admin", "admin", "654321", true
      token = storage.verify_user "admin", "654321"
      admin_token = State.get! "admin_token"
      token.should eq admin_token
    end
  end

  it "logs user out" do
    with_storage do |storage|
      user_token = State.get! "user_token"
      admin_token = State.get! "admin_token"
      storage.logout user_token
      storage.logout admin_token
      storage.verify_token(user_token).should be_nil
      storage.verify_token(admin_token).should be_nil
    end
  end

  it "cleans up" do
    with_storage do
      true
    end
    State.reset
  end
end
