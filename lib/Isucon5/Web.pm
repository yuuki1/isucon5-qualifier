package Isucon5::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Scope::Container::DBI;
use Encode;

my $db;
sub db {
  my %db = (
      host => $ENV{ISUCON5_DB_HOST} || 'localhost',
      port => $ENV{ISUCON5_DB_PORT} || 3306,
      username => $ENV{ISUCON5_DB_USER} || 'root',
      password => $ENV{ISUCON5_DB_PASSWORD},
      database => $ENV{ISUCON5_DB_NAME} || 'isucon5q',
  );
  # http://blog.nomadscafe.jp/2011/04/dbixsunny.html
  Scope::Container::DBI->connect(
      "dbi:mysql:database=$db{database};mysql_socket=/var/run/mysqld/mysqld.sock", $db{username}, $db{password}, {
          RootClass  => 'DBIx::Sunny',
          RaiseError => 1,
          PrintError => 0,
          AutoInactiveDestroy => 1,
          mysql_enable_utf8   => 1,
      },
  );
}

my $USERS = +{};
for (@{db->select_all("SELECT * FROM users")}) {
    $USERS->{$_->{id}} = $_;
    $USERS->{$_->{email}} = $_;
    $USERS->{$_->{account_name}} = $_;
}

my $SALTS = +{};
for (@{db->select_all("SELECT * FROM salts")}) {
    $SALTS->{$_->{user_id}} = $_;
}

my $PROFILES = +{};
for (@{db->select_all("SELECT * FROM profiles")}) {
    $PROFILES->{$_->{user_id}} = $_;
}

my ($SELF, $C);
sub session {
    $C->stash->{session};
}

sub stash {
    $C->stash;
}

sub redirect {
    $C->redirect(@_);
}

sub abort_authentication_error {
    session()->{user_id} = undef;
    $C->halt(401, encode_utf8($C->tx->render('login.tx', { message => 'ログインに失敗しました' })));
}

sub abort_permission_denied {
    $C->halt(403, encode_utf8($C->tx->render('error.tx', { message => '友人のみしかアクセスできません' })));
}

sub abort_content_not_found {
    $C->halt(404, encode_utf8($C->tx->render('error.tx', { message => '要求されたコンテンツは存在しません' })));
}

sub get_footprints_for_user_id {
    my ($user_id, $counts) = @_;
    my $footprints = [];
    my $footprints_map = +{}; # $footprints_map->{"$date$owner_id"} = 1;

    my $query = <<SQL;
SELECT user_id, owner_id, created_at_date, created_at as updated
FROM footprints
WHERE user_id = ?
ORDER BY created_at DESC
SQL
    for my $fp (@{db->select_all($query, $user_id)}) {
        my $key = $fp->{created_at_date} . $fp->{owner_id};
        # 同じ日の同じonwerからの足跡はskipする
        if ($footprints_map->{$key}) { next; }
        $footprints_map->{$key} = 1;

        my $owner = get_user($fp->{owner_id});
        $fp->{account_name} = $owner->{account_name};
        $fp->{nick_name} = $owner->{nick_name};
        push @$footprints, $fp;
        last if scalar @$footprints >= $counts;
    }
    return $footprints;
}

# 使ってない
sub _old_get_footprints_for_user_id {
    my ($user_id) = @_;
    my $query = <<SQL;
SELECT user_id, owner_id, MAX(created_at) as updated
FROM footprints
WHERE user_id = ?
GROUP BY user_id, owner_id, created_at_date
ORDER BY updated DESC
LIMIT 50
SQL
    my $footprints = [];
    for my $fp (@{db->select_all($query, $user_id)}) {
        my $owner = get_user($fp->{owner_id});
        $fp->{account_name} = $owner->{account_name};
        $fp->{nick_name} = $owner->{nick_name};
        push @$footprints, $fp;
    }
    return $footprints;
}

use Digest::SHA;
my $sha = Digest::SHA->new(512);
sub authenticate {
    my ($email, $password) = @_;

    my $user = $USERS->{$email};
    my $salt = $SALTS->{$user->{id}};

    my $result = $user->{passhash} eq $sha->add($password, $salt->{salt})->hexdigest;
    if (!$result) {
        abort_authentication_error();
    }
    session()->{user_id} = $user->{id};
    return $user;
}

sub current_user {
    my ($self, $c) = @_;
    my $user = stash()->{user};

    return $user if ($user);

    return undef if (!session()->{user_id});

    $user = get_user(session()->{user_id});
    if (!$user) {
        session()->{user_id} = undef;
        abort_authentication_error();
    }
    return $user;
}

sub get_user {
    my ($user_id) = @_;
    my $user = $USERS->{$user_id};
    abort_content_not_found() if (!$user);
    return $user;
}

sub user_from_account {
    my ($account_name) = @_;
    my $user = $USERS->{$account_name};
    abort_content_not_found() if (!$user);
    return $user;
}

sub friend_user_ids_of_user_id {
    my ($user_id) = (@_);
    my $friends_query = 'SELECT another FROM relations WHERE one = ? ORDER BY created_at DESC';
    return [ map { $_->{another} } @{db->select_all($friends_query, $user_id)} ];
}

sub is_friend {
    my ($another_id) = @_;
    my $user_id = session()->{user_id};
    my $query = 'SELECT COUNT(1) AS cnt FROM relations WHERE (one = ? AND another = ?)';
    my $cnt = db->select_one($query, $user_id, $another_id);
    return $cnt > 0 ? 1 : 0;
}

sub is_friend_account {
    my ($account_name) = @_;
    is_friend(user_from_account($account_name)->{id});
}

sub mark_footprint {
    my ($user_id) = @_;
    if ($user_id != current_user()->{id}) {
        my $query = 'INSERT INTO footprints (user_id,owner_id, created_at_date) VALUES (?,?, CURRENT_DATE())';
        db->query($query, $user_id, current_user()->{id});
    }
}

sub permitted {
    my ($another_id) = @_;
    $another_id == current_user()->{id} || is_friend($another_id);
}

my $PREFS;
sub prefectures {
    $PREFS ||= do {
        [
        '未入力',
        '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県', '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県', '新潟県', '富山県',
        '石川県', '福井県', '山梨県', '長野県', '岐阜県', '静岡県', '愛知県', '三重県', '滋賀県', '京都府', '大阪府', '兵庫県', '奈良県', '和歌山県', '鳥取県', '島根県',
        '岡山県', '広島県', '山口県', '徳島県', '香川県', '愛媛県', '高知県', '福岡県', '佐賀県', '長崎県', '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県'
        ]
    };
}

filter 'authenticated' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        if (!current_user()) {
            return redirect('/login');
        }
        $app->($self, $c);
    }
};

filter 'set_global' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $SELF = $self;
        $C = $c;
        $C->stash->{session} = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    }
};

get '/login' => sub {
    my ($self, $c) = @_;
    $c->render('login.tx', { message => '高負荷に耐えられるSNSコミュニティサイトへようこそ!' });
};

post '/login' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    my $email = $c->req->param("email");
    my $password = $c->req->param("password");
    authenticate($email, $password);
    redirect('/');
};

get '/logout' => [qw(set_global)] => sub {
    my ($self, $c) = @_;
    session()->{user_id} = undef;
    redirect('/login');
};

get '/' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;

    my $current_user = current_user();
    # { idA => 1, idB => 2, ... }
    my $friend_user_ids = friend_user_ids_of_user_id($current_user->{id});
    my $friend_user_id_maps = {};
    $friend_user_id_maps->{$_} = 1 for @$friend_user_ids;

    my $profile = $PROFILES->{$current_user->{id}};

    my $entries_query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5';
    my $entries = [];
    for my $entry (@{db->select_all($entries_query, $current_user->{id})}) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }

    my $comments_for_me_query = <<SQL;
SELECT * FROM comments
WHERE entry_user_id = ?
ORDER BY created_at DESC
LIMIT 10
SQL
    my $comments_for_me = [];
    my $comments = [];
    for my $comment (@{db->select_all($comments_for_me_query, $current_user->{id})}) {
        my $comment_user = get_user($comment->{user_id});
        $comment->{account_name} = $comment_user->{account_name};
        $comment->{nick_name} = $comment_user->{nick_name};
        push @$comments_for_me, $comment;
    }

    my $entries_of_friends = [];
    for my $entry (@{db->select_all('SELECT * FROM entries WHERE user_id IN (?) ORDER BY created_at DESC LIMIT 10', $friend_user_ids)}) {
#        next if ($friend_user_id_maps->{$entry->{user_id}});
        my ($title) = split(/\n/, $entry->{body});
        $entry->{title} = $title;
        my $owner = get_user($entry->{user_id});
        $entry->{account_name} = $owner->{account_name};
        $entry->{nick_name} = $owner->{nick_name};
        push @$entries_of_friends, $entry;
#        last if @$entries_of_friends+0 >= 10;
    }

    my $comments_of_friends = [];
    my $comments_of_friends_src = db->select_all('SELECT * FROM comments WHERE user_id IN (?) ORDER BY created_at DESC LIMIT 10', $friend_user_ids);
    my $comment_parent_entry_ids = [ map { $_->{entry_id} } @$comments_of_friends_src ];
    my $comment_parent_entries = db->select_all('SELECT * FROM entries WHERE id IN (?)', $comment_parent_entry_ids);
    my $comment_parent_entries_map = { map { $_->{id} => $_ } @$comment_parent_entries };
    for my $comment (@$comments_of_friends_src) {
#        next if ($friend_user_id_maps->{$comment->{user_id}});
        my $entry = $comment_parent_entries_map->{$comment->{entry_id}};
        $entry->{is_private} = ($entry->{private} == 1);
        # permittedの元々の実装のうち、is_friendの部分だけ既に引いてきたデータを参照する
        #     $another_id == current_user()->{id} || is_friend($another_id);
        next if ($entry->{is_private} && !($entry->{user_id} == $current_user->{id} || $friend_user_id_maps->{$entry->{user_id}}));
        my $entry_owner = get_user($entry->{user_id});
        $entry->{account_name} = $entry_owner->{account_name};
        $entry->{nick_name} = $entry_owner->{nick_name};
        $comment->{entry} = $entry;
        my $comment_owner = get_user($comment->{user_id});
        $comment->{account_name} = $comment_owner->{account_name};
        $comment->{nick_name} = $comment_owner->{nick_name};
        push @$comments_of_friends, $comment;
#        last if @$comments_of_friends+0 >= 10;
    }

    my $footprints = get_footprints_for_user_id($current_user->{id}, 10);

    my $locals = {
        'user' => $current_user,
        'profile' => $profile,
        'entries' => $entries,
        'comments_for_me' => $comments_for_me,
        'entries_of_friends' => $entries_of_friends,
        'comments_of_friends' => $comments_of_friends,
        'count_of_friends' => scalar(@$friend_user_ids) // 0,
        'footprints' => $footprints
    };
    $c->render('index.tx', $locals);
};

get '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = user_from_account($account_name);
    my $prof = $PROFILES->{$owner->{id}};
    $prof = {} if (!$prof);
    my $query;
    if (permitted($owner->{id})) {
        $query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5';
    } else {
        $query = 'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5';
    }
    my $entries = [];
    for my $entry (@{db->select_all($query, $owner->{id})}) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        profile => $prof,
        entries => $entries,
        private => permitted($owner->{id}),
        is_friend => is_friend($owner->{id}),
        current_user => current_user(),
        prefectures => prefectures(),
    };
    $c->render('profile.tx', $locals);
};

post '/profile/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    if ($account_name ne current_user()->{account_name}) {
        abort_permission_denied();
    }
    my $first_name =  $c->req->param('first_name');
    my $last_name = $c->req->param('last_name');
    my $sex = $c->req->param('sex');
    my $birthday = $c->req->param('birthday');
    my $pref = $c->req->param('pref');

    my $prof = $PROFILES->{current_user()->{id}};
    if ($prof) {
      my $query = <<SQL;
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
        db->query($query, $first_name, $last_name, $sex, $birthday, $pref, current_user()->{id});
    } else {
        my $query = <<SQL;
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
        db->query($query, current_user()->{id}, $first_name, $last_name, $sex, $birthday, $pref);
    }
    $PROFILES->{current_user()->{id}} = db->select_row('SELECT * FROM profiles WHERE user_id = ?', current_user()->{id});
    redirect('/profile/'.$account_name);
};

get '/diary/entries/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    my $owner = user_from_account($account_name);
    my $query;
    if (permitted($owner->{id})) {
        $query = 'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20';
    } else {
        $query = 'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20';
    }
    my $entries = [];
    my $entries_src = db->select_all($query, $owner->{id});
    # commentsといいつつcountだけ
    my $entry_comments = db->select_all('SELECT entry_id, COUNT(*) AS c FROM comments WHERE entry_id IN (?)', [ map { $_->{id} } @$entries_src ]);
    my $entry_id_to_comments_count = +{};
    for my $entry_comments (@$entry_comments) {
        $entry_id_to_comments_count->{$_->{entry_id}} = $_->{c};
    }

    for my $entry (@$entries_src) {
        $entry->{is_private} = ($entry->{private} == 1);
        my ($title, $content) = split(/\n/, $entry->{body}, 2);
        $entry->{title} = $title;
        $entry->{content} = $content;
        $entry->{comment_count} = $entry_id_to_comments_count->{$entry->{id}};
#        $entry->{comment_count} = db->select_one('SELECT COUNT(*) AS c FROM comments WHERE entry_id = ?', $entry->{id});
        push @$entries, $entry;
    }
    mark_footprint($owner->{id});
    my $locals = {
        owner => $owner,
        entries => $entries,
        myself => (current_user()->{id} == $owner->{id}),
    };
    $c->render('entries.tx', $locals);
};

get '/diary/entry/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    abort_content_not_found() if (!$entry);
    my ($title, $content) = split(/\n/, $entry->{body}, 2);
    $entry->{title} = $title;
    $entry->{content} = $content;
    $entry->{is_private} = ($entry->{private} == 1);
    my $owner = get_user($entry->{user_id});
    if ($entry->{is_private} && !permitted($owner->{id})) {
        abort_permission_denied();
    }
    my $comments = [];
    for my $comment (@{db->select_all('SELECT * FROM comments WHERE entry_id = ?', $entry->{id})}) {
        my $comment_user = get_user($comment->{user_id});
        $comment->{account_name} = $comment_user->{account_name};
        $comment->{nick_name} = $comment_user->{nick_name};
        push @$comments, $comment;
    }
    mark_footprint($owner->{id});
    my $locals = {
        'owner' => $owner,
        'entry' => $entry,
        'comments' => $comments,
    };
    $c->render('entry.tx', $locals);
};

post '/diary/entry' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)';
    my $title = $c->req->param('title');
    my $content = $c->req->param('content');
    my $private = $c->req->param('private');
    my $body = ($title || "タイトルなし") . "\n" . $content;
    db->query($query, current_user()->{id}, ($private ? '1' : '0'), $body);
    redirect('/diary/entries/'.current_user()->{account_name});
};

post '/diary/comment/:entry_id' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $entry_id = $c->args->{entry_id};
    my $entry = db->select_row('SELECT * FROM entries WHERE id = ?', $entry_id);
    abort_content_not_found() if (!$entry);
    $entry->{is_private} = ($entry->{private} == 1);
    if ($entry->{is_private} && !permitted($entry->{user_id})) {
        abort_permission_denied();
    }
    my $query = 'INSERT INTO comments (entry_id, entry_user_id, user_id, comment) VALUES (?,?,?,?)';
    my $comment = $c->req->param('comment');
    db->query($query, $entry->{id}, $entry->{user_id}, current_user()->{id}, $comment);
    redirect('/diary/entry/'.$entry->{id});
};

get '/footprints' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;

    my $footprints = get_footprints_for_user_id(current_user()->{id}, 50);
    $c->render('footprints.tx', { footprints => $footprints });
};

get '/friends' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $query = 'SELECT * FROM relations WHERE one = ? ORDER BY created_at DESC';
    my %friends = ();
    my $friends = [];
    for my $rel (@{db->select_all($query, current_user()->{id})}) {
        $friends{$rel->{another}} ||= do {
            my $friend = get_user($rel->{another});
            $rel->{account_name} = $friend->{account_name};
            $rel->{nick_name} = $friend->{nick_name};
            push @$friends, $rel;
            $rel;
        };
    }
    #my $friends = [ sort { $a->{created_at} lt $b->{created_at} } values(%friends) ];
    $c->render('friends.tx', { friends => $friends });
};

post '/friends/:account_name' => [qw(set_global authenticated)] => sub {
    my ($self, $c) = @_;
    my $account_name = $c->args->{account_name};
    if (!is_friend_account($account_name)) {
        my $user = user_from_account($account_name);
        abort_content_not_found() if (!$user);
        db->query('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user()->{id}, $user->{id}, $user->{id}, current_user()->{id});
        redirect('/friends');
    }
};

get '/initialize' => sub {
    my ($self, $c) = @_;

    db->query("DELETE FROM relations WHERE id > 500000");
    db->query("DELETE FROM footprints WHERE id > 500000");
    db->query("DELETE FROM entries WHERE id > 500000");
    db->query("DELETE FROM comments WHERE id > 1500000");
};

1;
