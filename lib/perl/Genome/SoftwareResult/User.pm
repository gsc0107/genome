package Genome::SoftwareResult::User;

use strict;
use warnings;
use Genome;
use Genome::Carp qw(dief);
use Genome::Sys::LockProxy qw();
use List::MoreUtils qw(any);
use Params::Validate qw(:types);
use Carp qw();

use Genome::Utility::Text;

class Genome::SoftwareResult::User {
    roles => ['Genome::Role::ObjectWithLockedConstruction'],
    table_name => 'result.user',
    id_by => [
        id => { is => 'Text', len => 32 },
    ],
    has => [
        software_result => {
            is => 'Genome::SoftwareResult',
            id_by => 'software_result_id',
            constraint_name => 'SRU_SR_FK',
        },
        user_class => {
            is => 'UR::Object::Type',
            id_by => 'user_class_name',
        },
        user_id => { is => 'Text', len => 256 },
        user => {
            is => 'UR::Object',
            id_by => 'user_id',
            id_class_by => 'user_class_name',
        },
        active => {
            is => 'Boolean',
            len => 1,
            default_value => 1,
            doc => 'Results actively being used should not be deleted',
        },
        label => { is => 'Text' },
    ],
    schema_name => 'GMSchema',
    data_source => 'Genome::DataSource::GMSchema',
    id_generator => '-uuid',
    doc => 'links a software result to other entities which depend on it',
};

sub with_registered_users {
    my $class = shift;
    my %params = Params::Validate::validate_with(
        params => \@_,
        spec   => {
            users => {
                type      => HASHREF,
                optional  => 0,
                callbacks => {
                    'must contain sponsor and requestor' => \&_validate_user_hash
                },
            },
            callback => {
                type     => CODEREF,
                optional => 0,
            }
        },
        allow_extra => 1,
    );

    my %user_hash = %{delete $params{users}}; #dereference to save a copy
    my $sr_callback = delete $params{callback};

    my ($software_result, $newly_created) = $sr_callback->(%params);
    return unless $software_result;

    $class->_register_users($software_result, \%user_hash, $newly_created);

    return $software_result;
}

sub _validate_user_hash {
    my $user_hash = shift;

    for my $type (qw( sponsor requestor )) {
        my $obj = $user_hash->{$type};
        return 0 unless($obj);
        return 0 unless ref($obj);
        return 0 unless $obj->does(_role_for_type($type));
    }

    return 1;
}

sub _register_users {
    my $class = shift;
    my $software_result = shift;
    my $user_hash = shift;
    my $newly_created = shift;

    my %user_hash = %$user_hash;

    my $requestor = delete $user_hash{requestor};
    my $label = $newly_created ? 'created' : 'shortcut';
    $user_hash{$label} = $requestor;

    my @param_sets;
    while(my ($label, $object) = each %user_hash) {
        my %params = (
            label           => $label,
            user            => $object,
            software_result => $software_result,
        );
        push @param_sets, \%params;
    }

    my $observer = UR::Context->process->add_observer(
        aspect => 'precommit',
        once => 1,
        callback => sub {
            for my $params (@param_sets) {
                next if grep { $params->{$_}->isa('UR::DeletedRef') } qw(user software_result);
                $class->create($params);
            }
        }
    );
    unless($observer) {
        die 'Failed to create observer';
    }
}

sub _role_for_type {
    return sprintf(
        'Genome::Role::SoftwareResult%s',
        ucfirst(shift)
    );
}

sub user_hash_for_build {
    my $class = shift;
    my $build = shift;
    unless ($build) {
        Carp::croak q(user_hash_for_build requires 'build' as an argument);
    }

    my $sponsor = $build->model->analysis_projects // Genome::Sys::User->get(username => $build->model->run_as);
    unless ($sponsor) {
        dief q(unable to determine sponsor for build: %s), $build->id;
    }

    return {
        requestor => $build,
        sponsor   => $sponsor,
    };
}

sub lock_id {
    my $class = shift;

    my $bx = $class->define_boolexpr(@_);

    my $label = $bx->value_for('label');
    if(length($label) >= 32) {
        $label = Genome::Sys->md5sum_data($label);
    }

    return Genome::Utility::Text::sanitize_string_for_filesystem(
        join('_', $label, $bx->value_for('user_id'), $bx->value_for('software_result_id'))
    );
}

1;

