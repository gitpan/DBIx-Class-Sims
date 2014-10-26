# vi:sw=2;ft=perl
package DBIx::Class::Sims;

use 5.008_004;

use strict;
use warnings FATAL => 'all';

use Data::Walk qw( walk );
use List::Util qw( shuffle );
use String::Random qw( random_regex );

our $VERSION = 0.05;

# Guarantee that toposort is loaded.
use base 'DBIx::Class::TopoSort';

{
  my %sim_types;

  sub set_sim_type {
    shift;
    my $types = shift;
    return unless ref($types||'') eq 'HASH';

    while ( my ($name, $meth) = each(%$types) ) {
      next unless ref($meth) eq 'CODE';

      $sim_types{$name} = $meth;
    }

    return;
  }
  BEGIN { *set_sim_types = \&set_sim_type; }

  sub sim_type {
    shift;

    return if @_ == 0;
    return $sim_types{$_[0]} if @_ == 1;
    return map { $sim_types{$_} } @_;
  }
  BEGIN { *sim_types = \&sim_type; }
}
use DBIx::Class::Sims::Types;

sub load_sims {
  my $self = shift;
  my ($spec_proto, $req_proto, $hooks) = @_;

  my $spec = expand_dots( normalize_input($spec_proto) );
  my $reqs = normalize_input($req_proto || {});

  ###### FROM HERE ######
  # These are utility methods to help navigate the rel_info hash.
  my $is_fk = sub { return exists $_[0]{attrs}{is_foreign_key_constraint} };
  my $short_source = sub {
    (my $x = $_[0]{source}) =~ s/.*:://;
    return $x;
  };

  my $self_fk_cols = sub { map {/^self\.(.*)/; $1} values %{$_[0]{cond}} };
  my $self_fk_col  = sub { ($self_fk_cols->(@_))[0] };
  my $foreign_fk_cols = sub { map {/^foreign\.(.*)/; $1} keys %{$_[0]{cond}} };
  my $foreign_fk_col  = sub { ($foreign_fk_cols->(@_))[0] };
  ###### TO HERE ######

  # 1. Ensure the belongs_to relationships are in $reqs
  # 2. Set the rel_info as the leaf in $reqs
  foreach my $name ( $self->sources ) {
    my $source = $self->source($name);

    $reqs->{$name} ||= {};
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);

      if ($is_fk->($rel_info)) {
        $reqs->{$name}{$rel_name} = 1;
      }
    }
  }

  # 2: Create the rows in toposorted order
  $hooks ||= {};
  $hooks->{preprocess}  ||= sub {};
  $hooks->{postprocess} ||= sub {};

  # Prepopulate column values (as appropriate)
  my %subs;
  $subs{fix_fk_dependencies} = sub {
    my ($name, $item) = @_;

    # 1. If we have something, then:
    #   a. If it's a scalar, then, COND = { $fk => scalar }
    #   b. Look up the row by COND
    #   c. If the row is not there, then $create_item->($fksrc, COND)
    # 2. If we don't have something, then:
    #   a. If rows exists, pick a random one.
    #   b. If rows don't exist, $create_item->($fksrc, {})
    my %child_deps;
    my $source = $self->source($name);
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);
      unless ( $is_fk->($rel_info) ) {
        if ($item->{$rel_name}) {
          $child_deps{$rel_name} = delete $item->{$rel_name};
        }
        next;
      }

      next unless $reqs->{$name}{$rel_name};

      my $col = $self_fk_col->($rel_info);
      my $fkcol = $foreign_fk_col->($rel_info);

      my $fk_src = $short_source->($rel_info);
      my $rs = $self->resultset($fk_src);

      if ( $item->{$rel_name} ) {
        my $cond = delete $item->{$rel_name};
        if ( ref($cond) ) {
          $rs = $rs->search($cond);
        }
        else {
          $rs = $rs->search({ $fkcol => $cond });
        }
      }
      elsif ( $item->{$col} ) {
        $rs = $rs->search({ $fkcol => $item->{$col} });
      }

      my $parent = $rs->first || $subs{create_item}->($fk_src, {});
      $item->{$col} = $parent->get_column($fkcol);
    }

    return \%child_deps;
  };
  $subs{fix_child_dependencies} = sub {
    my ($name, $row, $child_deps) = @_;

    # 1. If we have something, then:
    #   a. If it's not an array, then make it an array
    # 2. If we don't have something,
    #   a. Make an array with an empty item
    #   XXX This is more than one item would be supported
    # In all cases, make sure to add { $fkcol => $row->get_column($col) } to the
    # child's $item
    my $source = $self->source($name);
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);
      next if $is_fk->($rel_info);
      next unless $child_deps->{$rel_name} || $reqs->{$name}{$rel_name};

      my $col = $self_fk_col->($rel_info);
      my $fkcol = $foreign_fk_col->($rel_info);

      my $fk_src = $short_source->($rel_info);

      # Need to ensure that $child_deps >= $reqs

      my @children = @{$child_deps->{$rel_name} || []};
      @children = ( ({}) x $reqs->{$name}{$rel_name} ) unless @children;
      foreach my $child (@children) {
        $child->{$fkcol} = $row->get_column($col);
        $subs{create_item}->($fk_src, $child);
      }
    }
  };
  $subs{fix_columns} = sub {
    my ($name, $item) = @_;
    my $source = $self->source($name);
    foreach my $col_name ( $source->columns ) {
      next if exists $item->{$col_name};

      my $info = $source->column_info($col_name);
      next if grep { $_ eq $col_name } $source->primary_columns;

      if ( ref($info->{sim} || '') eq 'HASH' ) {
        if ( exists $info->{sim}{null_chance} && !$info->{nullable} ) {
          # Add check for not a number
          if ( rand() < $info->{sim}{null_chance} ) {
            $item->{$col_name} = undef;
            next;
          }
        }

        if ( ref($info->{sim}{func} || '') eq 'CODE' ) {
          $item->{$col_name} = $info->{sim}{func}->($info);
        }
        elsif ( exists $info->{sim}{value} ) {
          $item->{$col_name} = $info->{sim}{value};
        }
        elsif ( $info->{sim}{type} ) {
          my $meth = $self->sim_type($info->{sim}{type});
          if ( $meth ) {
            $item->{$col_name} = $meth->($info);
          }
          else {
            warn "Type '$info->{sim}{type}' is not loaded";
          }
        }
        else {
          if ( $info->{data_type} eq 'int' ) {
            my $min = $info->{sim}{min} || 0;
            my $max = $info->{sim}{max} || 100;
            $item->{$col_name} = int(rand($max-$min))+$min;
          }
          elsif ( $info->{data_type} eq 'varchar' ) {
            my $min = $info->{sim}{min} || 1;
            my $max = $info->{sim}{max} || $info->{data_length} || 255;
            $item->{$col_name} = random_regex(
              '\w' . "{$min,$max}"
            );
          }
        }
      }
    }
  };
  $subs{create_item} = sub {
    my ($name, $item) = @_;

    my $child_deps = $subs{fix_fk_dependencies}->($name, $item);
    $subs{fix_columns}->($name, $item);

    my $source = $self->source($name);
    $hooks->{preprocess}->($name, $source, $item);
    my $row = $self->resultset($name)->create($item);
    $hooks->{postprocess}->($name, $source, $row);

    $subs{fix_child_dependencies}->($name, $row, $child_deps);

    return $row;
  };

  my %ids;
  $self->txn_do(sub {
    foreach my $name ( grep { $spec->{$_} } $self->toposort() ) {
      my @pk_cols = $self->source($name)->primary_columns;
      foreach my $item ( @{$spec->{$name}} ) {
        my $row = $subs{create_item}->($name, $item);
        push @{ $ids{$name} ||= [] }, {( map { $_ => $row->$_ } @pk_cols )};
      }
    }
  });

  return \%ids;
}

use YAML::Any qw( LoadFile Load );
sub normalize_input {
  my ($proto) = @_;

  if ( ref($proto) ) {
    return $proto;
  }

  # Doing a stat on a filename with a newline throws an error.
  my $x = eval {
    if ( -e $proto ) {
      return LoadFile($proto);
    }
  };
  return $x if $x;

  return Load($proto);
}

sub expand_dots {
  my $struct = shift;

  walk sub {
    if ( ref($_) eq 'HASH' ) {
      foreach my $k ( keys %$_ ) {
        my $t = $_;
        while ( $k =~ /([^.]*)\.(.*)/ ) {
          $t->{$1} = { $2 => delete($t->{$k}) };
          $t = $t->{$1}; $k = $2;
        }
      }
    }
  }, $struct;

  return $struct;
}

1;
__END__

=head1 NAME

DBIx::Class::Sims - The addition of simulating data to DBIx::Class

=head1 SYNOPSIS

Within your schema class:

  __PACKAGE__->load_components('Sims');

Within your resultsources, specify the sims generation rules for columns that
need specified.

  __PACKAGE__->add_columns(
    ...
    address => {
      data_type => 'varchar',
      is_nullable => 1,
      data_length => 10,
      sim => { type => 'us_address' },
    },
    zipcode => {
      data_type => 'varchar',
      is_nullable => 1,
      data_length => 10,
      sim => { type => 'us_zipcode' },
    },
    column1 => {
      data_type => 'int',
      is_nullable => 0,
      sim => {
        min => 10,
        max => 20,
      },
    },
    column2 => {
      data_type => 'varchar',
      is_nullable => 1,
      data_length => 10,
      default_value => 'foobar',
    },
    ...
  );

Later:

  $schema->deploy({
    add_drop_table => 1,
  });

  my $ids = $schema->load_sims({
    Table1 => [
      {}, # Take sims or default values for everything
      { # Override some values, take sim values for others
        column1 => 20,
        column2 => 'something',
      },
    ],
  });

=head1 PURPOSE

Generating test data for non-simplistic databases is extremely hard, especially
as the schema grows and changes. Designing scenarios B<should> be doable by only
specifying the minimal elements actually used in the test with the test being
resilient to any changes in the schema that don't affect the elements specified.
This includes changes like adding a new parent table, new required child tables,
and new non-NULL columns to the table being tested.

With Sims, you specify only what you care about. Any required parent rows are
automatically generated. If a row requires a certain number of child rows (all
artists must have one or more albums), that can be set as well. If a column must
have specific data in it (a US zipcode or a range of numbers), you can specify
that in the table definition.

And, in all cases, you can override anything.

=head1 DESCRIPTION

This is a L<DBIx::Class> component that adds a few methods to your
L<DBIx::Class::Schema> object. These methods make it much easier to create data
for testing purposes (though, obviously, it's not limited to just test data).

=head1 METHODS

=head2 load_sims

C<< $rv = $schema->load_sims( $spec, ?$constraints, ?$hooks ) >>

This method will load the rows requested in C<$spec>, plus any additional rows
necessary to make those rows work. This includes any parent rows (as defined by
C<belongs_to>) and per any constraints defined in C<$constraints>. If need-be,
you can pass in hooks (as described below) to manipulate the data.

load_sims does all of its work within a call to L<DBIx::Class::Schema/txn_do>.
If anything goes wrong, load_sims will rethrow the error after the transaction
is rolled back.

This, of course, assumes that the tables you are working with support
transactions. (I'm looking at you, MyISAM!) If they do not, that is on you.

=head3 Return value

This will return a hash of arrays of hashes. This will match the C<$spec>,
except that where the C<$spec> has a requested set of things to make, the return
will have the primary columns.

Examples:

If you have a table foo with "id" as the primary column and you requested:

  {
    Foo => [
      { name => 'bar' },
    ],
  }

You will receive back (assuming the next id value is 1):

  {
    Foo => [
      { id => 1 },
    ],
  }

If you have a table foo with "name" and "type" as the primary columns and you
requested:

  {
    Foo => [
      { children => [ {} ] },
    ],
  }

You will receive back (assuming the next PK values are as below):

  {
    Foo => [
      { name => 'bar', type => 'blah' },
    ],
  }

Note that you do not get back the ids for any additional rows generated (such as
for the children). 

=head2 set_sim_type

C<< $class_or_obj->set_sim_type({ $name => $handler, ... }); >>

This method will set the handler for the C<$name> sim type. The handler must be
a reference to a subroutine. You may pass in as many name/handler pairs as you
like.

This method may be called as a class or object method.

This method returns nothing.

C<set_sim_types()> is an alias to this method.

=head1 SPECIFICATION

The specification can be passed along as a filename that contains YAML or JSON,
a string that contains YAML or JSON, or as a hash of arrays of hashes. The
structure should look like:

  {
    ResultSourceName => [
      {
        column => $value,
        column => $value,
        relationship => {
          column => $value,
        },
        'relationship.column' => $value,
        'rel1.rel2.rel3.column' => $value,
      },
    ],
  }

If a column is a belongs_to relationship name, then the row associated with that
relationship specifier will be used. This is how you would specify a specific
parent-child relationship. (Otherwise, a random choice will be made as to which
parent to use, creating one as necessary if possible.) The dots will be followed
as far as necessary.

Columns that have not been specified will be populated in one of two ways. The
first is if the database has a default value for it. Otherwise, you can specify
the C<sim> key in the column_info for that column. This is a new key that is not
used by any other component. See L</SIM ENTRY> for more information.

(Please see L<DBIx::Class::ResultSource/add_columns> for details on column_info)

B<NOTE>: The keys of the outermost hash are resultsource names. The keys within
the row-specific hashes are either columns or relationships. Not resultsources.

=head1 CONSTRAINTS

The constraints can be passed along as a filename that contains YAML or JSON, a
string that contains YAML or JSON, or as a hash of arrays of hashes. The
structure should look like:

  {
    Person => {
      addresses => 2,
    },
  }

All the C<belongs_to> relationships are automatically added to the constraints.
You can add additional constraints, as needed. The most common use for this will
be to add required child rows. For example, C<< Person->has_many('addresses') >>
would normally mean that if you create a Person, no Address rows would be
created.  But, we could specify a constraint that says "Every person must have
at least 2 addresses." Now, whenever a Person is created, two Addresses will be
added along as well, if they weren't already created through some other
specification.

=head1 HOOKS

Most people will never need to use this. But, some schema definitions may have
reasons that prevent a clean simulating with this module. For example, there may
be application-managed sequences. To that end, you may specify the following
hooks:

=over 4

=item * preprocess

This receives C<$name, $source, $spec> and expects nothing in return. C<$spec>
is the hashref that will be passed to C<<$schema->resultset($name)->create()>>.
This hook is expected to modify C<$spec> as needed.

=item * postprocess

This receives C<$name, $source, $row> and expects nothing in return. This hook
is expected to modify the newly-created row object as needed.

=back

=head1 SIM ENTRY

To control how a column's values are simulated, add a "sim" entry in the
column_info for that column. The sim entry is a hash that can have the followingkeys:

=over 4

=item * value

This behaves just like default_value would behave, but doesn't require setting a
default value on the column.

  sim => {
      value => 'The value to always use',
  },

=item * type

This labels the column as having a certain type. A type is registered using
L</set_sim_type>. The type acts as a name for a function that's used to generate
the value. See L</Types> for more information.

=item * min / max

If the column is numeric, then the min and max bound the random value generated.
If the column is a string, then the min and max are the length of the random
value generated.

=item * func

This is a function that is provided the column info. Its return value is used to
populate the column.

=item * null_chance

If the column is nullable I<and> this is set I<and> it is a number between 0 and
1, then if C<rand()> is less than that number, the column will be set to null.
Otherwise, the standard behaviors will apply.

If the column is B<not> nullable, this setting is ignored.

=back

(Please see L<DBIx::Class::ResultSource/add_columns> for details on column_info)

=head2 Types

The handler for a sim type will receive the column info (as defined in
L<DBIx::Class::ResultSource/add_columns>). From that, the handler returns the
value that will be used for this column.

Please see L<DBIx::Class::Sims::Types> for the list of included sim types.

=head1 TODO

=head2 Multi-column types

In some applications, columns like "state" and "zipcode" are correlated. Values
for one must be legal for the value in the other. The Sims currently has no way
of generating correlated columns like this.

This is most useful for saying "These 6 columns should be a coherent address".

=head2 Allow a column to reference other columns

Sometimes, a column should alter its behavior based on other columns. A fullname
column may have the firstname and lastname columns concatenated, with other
things thrown in. Or, a zipcode column should only generate a zipcode that's
legal for the state.

=head1 BUGS/SUGGESTIONS

This module is hosted on Github at
L<https://github.com/robkinyon/dbix-class-sims>. Pull requests are strongly
encouraged.

=head1 DBIx::Class::Fixtures

L<DBIx::Class::Fixtures> is another way to load data into a database. Unlike
this module, L<DBIx::Class::Fixtures> approaches the problem by loading the same
data every time. This is complementary because some tables (such as lookup
tables of countries) want to be seeded with the same data every time. The ideal
solution would be to have a set of tables loaded with fixtures and another set
of tables loaded with sims.

=head1 SEE ALSO

L<DBIx::Class>, L<DBIx::Class::Fixtures>

=head1 AUTHOR

Rob Kinyon <rob.kinyon@gmail.com>

=head1 LICENSE

Copyright (c) 2013 Rob Kinyon. All Rights Reserved.
This is free software, you may use it and distribute it under the same terms
as Perl itself.

=cut
