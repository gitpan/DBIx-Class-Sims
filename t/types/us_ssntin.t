# vi:sw=2
use strict;
use warnings FATAL => 'all';

use Test::More;

use_ok 'DBIx::Class::Sims::Types';

my $sub = DBIx::Class::Sims::Types->can('us_ssntin');

my $info = {
  data_type => 'varchar',
  sim => { type => 'us_ssntin' },
};
my $expected = qr/^(?:\d{3}-\d{2}-\d{4})|(?:\d{2}-\d{7})$/;
for ( 1 .. 1000 ) {
  like( $sub->($info), $expected );
}

done_testing;
