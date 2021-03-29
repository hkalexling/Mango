class CreateSubscription < MG::Base
  def up : String
    # We allow multiple subscriptions for the same manga.
    # This can be useful for example when you want to download from multiple
    #   groups.
    <<-SQL
    CREATE TABLE subscription (
      id INTEGER PRIMARY KEY,
      manga_id INTEGER NOT NULL,
      language TEXT,
      group_id INTEGER,
      min_volume INTEGER,
      max_volume INTEGER,
      min_chapter INTEGER,
      max_chapter INTEGER,
      last_checked INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      username TEXT NOT NULL,
      FOREIGN KEY (username) REFERENCES users (username)
        ON UPDATE CASCADE
        ON DELETE CASCADE
    );
    SQL
  end

  def down : String
    <<-SQL
    DROP TABLE subscription;
    SQL
  end
end
