package Bric::App::Callback::ContainerProf;

use base qw(Bric::App::Callback);
__PACKAGE__->register_subclass;
use constant CLASS_KEY => 'container_prof';

use strict;
use Bric::App::Session qw(:state);
use Bric::App::Util qw(:all);
use Bric::App::Event qw(log_event);
use Bric::Biz::AssetType;
use Bric::Biz::AssetType::Parts::Data;
use Bric::Biz::Asset::Business::Parts::Tile::Container;
use Bric::Biz::Asset::Business::Parts::Tile::Data;
use Text::Levenshtein;
use Text::Soundex;


my $STORY_URL = '/workflow/profile/story';
my $CONT_URL  = '/workflow/profile/story/container';
my $MEDIA_URL = '/workflow/profile/media';
my $MEDIA_CONT = '/workflow/profile/media/container';

my $regex = {
    "\n" => qr/\s*\n\n|\r\r\s*/,
    '<p>' => qr/\s*<p>\s*/,
    '<br>' => qr/\s*<br>\s*/,
};

my %pkgs = (
    story => get_package_name('story'),
    media => get_package_name('media'),
);

my ($push_tile_stack, $pop_tile_stack, $pop_and_redirect,
    $delete_element, $update_parts, $handle_related_up,
    $save_data, $handle_bulk_up, $handle_bulk_save, $super_save_data,
    $split_fields, $compare_soundex, $compare_levenshtein,
    $compare, $closest, $split_super_bulk, $drift_correction);


sub edit : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $r = $self->apache_req;

    my $tile = get_state_data(CLASS_KEY, 'tile');

    # Update the existing fields and get the child tile matching ID
    my $edit_tile = $update_parts->($self, $param);

    # Push this child tile on top of the stack
    $push_tile_stack->(CLASS_KEY, $edit_tile);

    # Don't redirect if we're already on the right page.
    if ($tile->get_object_type eq 'media') {
        unless ($r->uri eq "$MEDIA_CONT/edit.html") {
            set_redirect("$MEDIA_CONT/edit.html");
        }
    } else {
        unless ($r->uri eq "$CONT_URL/edit.html") {
            set_redirect("$CONT_URL/edit.html");
        }
    }
}

sub bulk_edit : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $r = $self->apache_req;
    my $field = $self->trigger_key;

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $tile_id = $param->{'edit_view_bulk_tile_id'};
    # Update the existing fields and get the child tile matching ID $tile_id
    my $edit_tile = $update_parts->($self, $param);

    # Push the current tile onto the stack.
    $push_tile_stack->(CLASS_KEY, $edit_tile);

    # Get the name of the field to bulk edit
    my $field = $param->{CLASS_KEY.'|bulk_edit_tile_field-'.$tile_id};

    # Save the bulk edit field name
    set_state_data(CLASS_KEY, 'field', $field);
    set_state_data(CLASS_KEY, 'view_flip', 0);

    my $state_name = $field eq '_super_bulk_edit' ? 'edit_super_bulk'
                                                  : 'edit_bulk';
    set_state_name(CLASS_KEY, $state_name);

    my $uri  = $tile->get_object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
    set_redirect("$uri/$state_name.html");
}

sub view : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $r = $self->apache_req;
    my $field = $self->trigger_key;

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $tile_id = $param->{'edit_view_bulk_tile_id'};
    my ($view_tile) = grep(($_->get_id == $tile_id), $tile->get_containers);

    # Push this child tile on top of the stack
    $push_tile_stack->(CLASS_KEY, $view_tile);

    if ($tile->get_object_type eq 'media') {
        set_redirect("$MEDIA_CONT/") unless $r->uri eq "$MEDIA_CONT/";
    } else {
        set_redirect("$CONT_URL/") unless $r->uri eq "$CONT_URL/";
    }
}

sub reorder : Callback {
    # don't do anything, handled by the update_parts code now
}

sub delete : Callback {
    # don't do anything, handled by the update_parts code now
}

sub clear : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    clear_state(CLASS_KEY);
}

sub add_element : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $r = $self->apache_req;

    # get the tile
    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $key = $tile->get_object_type();
    # Get this tile's asset object if it's a top-level asset.
    my $a_obj;
    if (Bric::Biz::AssetType->lookup({id => $tile->get_element_id()})->get_top_level()) {
        $a_obj = $pkgs{$key}->lookup({id => $tile->get_object_instance_id()});
    }
    my $fields = mk_aref($self->request_args->{CLASS_KEY . '|add_element'});

    foreach my $f (@$fields) {
        my ($type,$id) = unpack('A5 A*', $f);
        my $at;
        if ($type eq 'cont_') {
            $at = Bric::Biz::AssetType->lookup({id=>$id});
            my $cont = $tile->add_container($at);
            $tile->save();
            $push_tile_stack->(CLASS_KEY, $cont);

            if ($key eq 'story') {
                # Don't redirect if we're already at the edit page.
                set_redirect("$CONT_URL/edit.html")
                  unless $r->uri eq "$CONT_URL/edit.html";
            } else {
                set_redirect("$MEDIA_CONT/edit.html")
                  unless $r->uri eq "$MEDIA_CONT/edit.html";
            }

        } elsif ($type eq 'data_') {
            $at = Bric::Biz::AssetType::Parts::Data->lookup({id=>$id});
            $tile->add_data($at, '');
            $tile->save();
            set_state_data(CLASS_KEY, 'tile', $tile);
        }
        log_event($key.'_add_element', $a_obj, {Element => $at->get_key_name})
          if $a_obj;
    }
}

sub update : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    $update_parts->($self, $self->request_args);
    my $tile = get_state_data(CLASS_KEY, 'tile');
    $tile->save();
}

sub pick_related_media : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $object_type = $tile->get_object_type();
    my $uri = $object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
    set_redirect("$uri/edit_related_media.html");
}

sub relate_media : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    $tile->set_related_media($self->value);
    &$handle_related_up;
}

sub unrelate_media : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    $tile->set_related_media(undef);
    &$handle_related_up;
}

sub pick_related_story : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $object_type = $tile->get_object_type();
    my $uri = $object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
    set_redirect("$uri/edit_related_story.html");
}

sub relate_story : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    $tile->set_related_instance_id($self->value);
    &$handle_related_up;
}

sub unrelate_story : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $tile = get_state_data(CLASS_KEY, 'tile');
    $tile->set_related_instance_id(undef);
    &$handle_related_up;
}

sub related_up : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    &$handle_related_up;
}

sub lock_val : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $value = $self->value;
    my $autopop = ref $self->value ? $self->value : [$self->value];
    my $tile    = get_state_data(CLASS_KEY, 'tile');

    # Map all the data tiles into a hash keyed by Tile::Data ID.
    my $data = { map { $_->get_id() => $_ } 
                 grep(not($_->is_container()), $tile->get_tiles()) };

    foreach my $id (@$autopop) {
        my $lock_set = $self->request_args->{CLASS_KEY.'|lock_val_'.$id} || 0;
        my $dt = $data->{$id};

        # Skip if there is no data tile here.
        next unless $dt;
        if ($lock_set) {
            $dt->lock_val();
        } else {
            $dt->unlock_val();
        }
    }
}

sub save_and_up : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    if ($self->request_args->{CLASS_KEY . '|delete_element'}) {
        $delete_element->($self);
        return;
    }

    if (get_state_data(CLASS_KEY, '__NO_SAVE__')) {
        # Do nothing.
        set_state_data(CLASS_KEY, '__NO_SAVE__', undef);
    } else {
        # Save the tile we are working on.
        my $tile = get_state_data(CLASS_KEY, 'tile');
        $tile->save();
        add_msg('Element &quot;' . $tile->get_name . '&quot; saved.');
        $pop_and_redirect->($self, CLASS_KEY);
    }
}

sub save_and_stay : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    if ($self->request_args->{CLASS_KEY . '|delete_element'}) {
        $delete_element->($self);
        return;
    }

    if (get_state_data(CLASS_KEY, '__NO_SAVE__')) {
        # Do nothing.
        set_state_data(CLASS_KEY, '__NO_SAVE__', undef);
    } else {
        # Save the tile we are working on
        my $tile = get_state_data(CLASS_KEY, 'tile');
        $tile->save();
        add_msg('Element &quot;' . $tile->get_name . '&quot; saved.');
    }
}

sub up : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    $pop_and_redirect->($self, CLASS_KEY);
}

# bulk edit callbacks

sub resize : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $param = $self->request_args;

    $split_fields->(CLASS_KEY, $param->{CLASS_KEY.'|text'});
    set_state_data(CLASS_KEY, 'rows', $param->{CLASS_KEY.'|rows'});
    set_state_data(CLASS_KEY, 'cols', $param->{CLASS_KEY.'|cols'});
}

sub change_default_field : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $def  = $self->request_args->{CLASS_KEY.'|default_field'};
    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $at   = $tile->get_element();

    my $key = 'container_prof.' . $at->get_id . '.def_field';
    set_state_data('_tmp_prefs', $key, $def);
}

sub change_sep : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my ($data, $sep);

    # Save off the custom separator in case it changes.
    set_state_data(CLASS_KEY, 'custom_sep', $param->{CLASS_KEY.'|custom_sep'});

    # First split the fields along the old boundary character.
    $split_fields->(CLASS_KEY, $param->{CLASS_KEY.'|text'});

    # Now load the new separator
    $sep = $param->{CLASS_KEY.'|separator'};

    if ($sep ne 'custom') {
        set_state_data(CLASS_KEY, 'separator', $sep);
        set_state_data(CLASS_KEY, 'use_custom_sep', 0);
    } else {
        set_state_data(CLASS_KEY, 'separator', $param->{CLASS_KEY.'|custom_sep'});
        set_state_data(CLASS_KEY, 'use_custom_sep', 1);
    }

    # Get the data and pass it back to be resplit against the new separator
    $data = get_state_data(CLASS_KEY, 'data');
    $sep  = get_state_data(CLASS_KEY, 'separator');
    $split_fields->(CLASS_KEY, join("\n$sep\n", @$data));
    add_msg("Separator Changed.");
}

sub recount : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    $split_fields->(CLASS_KEY, $self->request_args->{CLASS_KEY.'|text'});
}

sub bulk_edit_this : Callback {
    my $self = shift;
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    my $be_field = $self->request_args->{CLASS_KEY . '|bulk_edit_field'};

    # Save the bulk edit field name
    set_state_data(CLASS_KEY, 'field', $be_field);
    # Note that we are just 'flipping' the current view of this tile.  That is,
    # it's the same tile, same data, but different view of it.
    set_state_data(CLASS_KEY, 'view_flip', 1);

    my $state_name = $be_field eq '_super_bulk_edit' ? 'edit_super_bulk'
                                                     : 'edit_bulk';
    set_state_name(CLASS_KEY, $state_name);

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $uri  = $tile->get_object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;

    set_redirect("$uri/$state_name.html");
}

sub bulk_save : Callback {
    my ($self) = @_;     # @_ for &$handle_related_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    &$handle_bulk_save;
}

sub bulk_up : Callback {
    my ($self) = @_;     # @_ for &$handle_bulk_up
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    &$handle_bulk_up;
}

sub bulk_save_and_up : Callback {
    my ($self) = @_;     # @_ for &$handle_bulk_*
    $drift_correction->($self);
    my $param = $self->request_args;
    return if $param->{'_inconsistent_state_'};

    &$handle_bulk_save;
    &$handle_bulk_up;
}


####################
## Misc Functions ##

$push_tile_stack = sub {
    my ($widget, $new_tile) = @_;

    # Push the current tile onto the stack.
    my $tiles    = get_state_data($widget, 'tiles');
    my $cur_tile = get_state_data($widget, 'tile');
    push @$tiles, $cur_tile;

    my $crumb = '';
    foreach my $t (@$tiles[1..$#$tiles]) {
        $crumb .= ' &quot;' . $t->get_name . '&quot;' . ' |';
    }
    $crumb .= ' &quot;' . $new_tile->get_name . '&quot;';

    set_state_data($widget, 'crumb', $crumb);
    set_state_data($widget, 'tiles', $tiles);
    set_state_data($widget, 'tile', $new_tile);
};

$pop_tile_stack = sub {
    my ($widget) = @_;

    my $tiles = get_state_data($widget, 'tiles');
    my $parent_tile = pop @$tiles;

    my $crumb = '';
    foreach my $t (@$tiles[1..$#$tiles]) {
        $crumb .= ' &quot;' . $t->get_name . '&quot;' . ' |';
    }
    $crumb .= ' &quot;' . $parent_tile->get_name . '&quot;';

    set_state_data($widget, 'crumb', $crumb);
    set_state_data($widget, 'tile', $parent_tile);
    set_state_data($widget, 'tiles', $tiles);
    return $parent_tile;
};

$pop_and_redirect = sub {
    my ($self, $widget, $flip) = @_;
    my $r = $self->apache_req;

    # Get the tile stack and pop off the current tile.
    my $tile = $flip ? get_state_data($widget, 'tile')
                     : $pop_tile_stack->($widget);

    my $object_type = $tile->get_object_type;

    # If our tile has parents, show the regular edit screen.
    if ($tile->get_parent_id) {
        my $uri = $object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
        my $page = get_state_name($widget) eq 'view' ? '' : 'edit.html';

        #  Don't redirect if we're already at the right URI
        set_redirect("$uri/$page") unless $r->uri eq "$uri/$page";
    }
    # If our tile doesn't have parents go to the main story edit screen.
    else {
        my $uri = $object_type eq 'media' ? $MEDIA_URL : $STORY_URL;
        set_redirect($uri);
    }
};

$delete_element = sub {
    my $self = shift;
    my $r = $self->apache_req;
    my $widget = CLASS_KEY;

    my $tile = get_state_data($widget, 'tile');
    my $parent = $pop_tile_stack->($widget);
    $parent->delete_tiles( [ $tile ]);
    $parent->save();
    my $object_type = $parent->get_object_type;

    # if our tile has parents, show the regular edit screen.
    if ($parent->get_parent_id) {
        my $uri = $object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
        my $page = get_state_name($widget) eq 'view' ? '' : 'edit.html';

        #  Don't redirect if we're already at the right URI
        set_redirect("$uri/$page") unless $r->uri eq "$uri/$page";
    }
    # If our tile doesn't have parents go to the main story edit screen.
    else {
        my $uri = $object_type eq 'media' ? $MEDIA_URL : $STORY_URL;
        set_redirect($uri);
    }

    my $arg = '&quot;' . $tile->get_name . '&quot;';
    add_msg($self->lang->maketext('Element [_1] deleted.', $arg));
    return;
};


$update_parts = sub {
    my ($self, $param) = @_;
    my (@curr_tiles, @delete, $locate_tile);

    my $widget = CLASS_KEY;
    my $locate_id = exists $param->{'edit_view_bulk_tile_id'}
      ? $param->{'edit_view_bulk_tile_id'}
      : -1;    # invalid ID
    my $tile = get_state_data($widget, 'tile');

    # Don't delete unless either the 'Save...' or 'Delete' buttons were pressed
    my $do_delete = ($param->{$widget.'|delete_cb'} ||
                     $param->{$widget.'|save_and_up_cb'} ||
                     $param->{$widget.'|save_and_stay_cb'});

    # Save data to tiles and put them in a usable order
    foreach my $t ($tile->get_tiles) {
        my $id = $t->get_id();

        # Grab the tile we're looking for
        local $^W = undef;
        $locate_tile = $t if $id == $locate_id and $t->is_container;
        if ($do_delete && ($param->{$widget . "|delete_cont$id"} ||
                           $param->{$widget . "|delete_data$id"})) {

            my $arg = '&quot;' . $t->get_name . '&quot;';
            add_msg($self->lang->maketext("Element [_1] deleted.", $arg));
            push @delete, $t;
            next;
        }

        my ($order, $redir);
        if ($t->is_container) {
            $order = $param->{$widget . "|reorder_con$id"};
        } else {
            $order = $param->{$widget . "|reorder_dat$id"};
            if (! $t->is_autopopulated or exists
                $param->{$widget . "|lock_val_$id"}) {
                my $val = $param->{$widget . "|$id"};
                $val = '' unless defined $val;
                if ( $param->{$widget . "|${id}-partial"} ) {
                    # The date is only partial. Send them back to to it again.
                    my $msg = 'Invalid date value for [_1] field.';
                    my $arg = '&quot;' . $_->get_name. '&quot;';
                    add_msg($self->lang->maketext($msg, $arg));
                    set_state_data($widget, '__NO_SAVE__', 1);
                } else {
                    # Truncate the value, if necessary, then set it.
                    my $info = $t->get_element_data_obj->get_meta('html_info');
                    $val = join('__OPT__', @$val) if $info->{multiple} && ref $val;
                    my $max = $info->{maxlength};
                    $val = substr($val, 0, $max) if $max && length $val > $max;
                    $t->set_data($val);
                }
            }
        }

        $curr_tiles[$order] = $t;
    }

    # Delete tiles as necessary.
    $tile->delete_tiles(\@delete) if $do_delete;

    if (@curr_tiles) {
        eval { $tile->reorder_tiles([grep(defined($_), @curr_tiles)]) };
        if ($@) {
            add_msg("Warning! State inconsistent: Please use the buttons "
                      . "provided by the application rather than the "
                      . "'Back'/'Forward' buttons.");
            return;
        }
    }

    set_state_data($widget, 'tile', $tile);
    return $locate_tile;
};

$handle_related_up = sub {
    my ($self) = @_;
    my $r = $self->apache_req;

    my $tile = get_state_data(CLASS_KEY, 'tile');
    my $object_type = $tile->get_object_type();

    # If our tile has parents, show the regular edit screen.
    if ($tile->get_parent_id()) {
        my $uri = $object_type eq 'media' ? $MEDIA_CONT : $CONT_URL;
        my $page = get_state_name(CLASS_KEY) eq 'view' ? '' : 'edit.html';

        #  Don't redirect if we're already at the right URI
        set_redirect("$uri/$page") unless $r->uri eq "$uri/$page";
    }
    # If our tile doesn't have parents go to the main story edit screen.
    else {
        my $uri = $object_type eq 'media' ? $MEDIA_URL : $STORY_URL;
        set_redirect($uri);
    }
    pop_page();
};


################################################################################
## Bulk Edit Helper Functions

#------------------------------------------------------------------------------#
# save_data
#
# Split out the text entered into the bulk edit text box into chuncks and save
# each chunk into its own element, reusing existing elements if possible and
# creating new ones otherwise.

$save_data = sub {
    my ($widget) = @_;

    # The tile currently being edited by container_prof
    my $tile   = get_state_data($widget, 'tile');
    # The field within the tile being edited via bulk edit
    my $field  = get_state_data($widget, 'field');
    # Data tiles already created while editing the field in bulk_edit
    my $dtiles = get_state_data($widget, 'dtiles') || [];
    # The most recent data entered into bulk edit
    my $data   = get_state_data($widget, 'data');

    # Get the asset type data object.
    my $at_id = $tile->get_element_id;
    my $at    = Bric::Biz::AssetType->lookup({'id' => $at_id});
    my $atd   = $at->get_data($field);

    foreach my $d (@$data) {
        my $dt;

        if (@$dtiles) {
            # Fill the existing tiles first.
            $dt = shift @$dtiles;
        } else {
            # Otherwise create new tiles.
            $dt = Bric::Biz::Asset::Business::Parts::Tile::Data->new
              ({ 'element_data' => $atd,
                 'object_type'  => 'story' });
            $tile->add_tile($dt);
        }

        # Set the data on this tile.
        $dt->set_data($d);
    }

    # Delete any remaining tiles that haven't been filled.
    $tile->delete_tiles($dtiles) if scalar(@$dtiles);

    # Save the tile
    $tile->save;

    # Grab only the tiles that have the name $field
    my @dtiles = grep($_->get_key_name eq $field, $tile->get_tiles());

    set_state_data($widget, 'dtiles', \@dtiles);
};

$handle_bulk_up = sub {
    my ($self) = @_;

    # Set the state back to edit mode.
    set_state_name(CLASS_KEY, 'edit');

    # Clear some values.
    set_state_data(CLASS_KEY, 'dtiles',   undef);
    set_state_data(CLASS_KEY, 'data',     undef);
    set_state_data(CLASS_KEY, 'field',    undef);

    # If the view has been flipped, just flip it back.
    if (get_state_data(CLASS_KEY, 'view_flip')) {
        # Set flip back to false.
        set_state_data(CLASS_KEY, 'view_flip', 0);
        $pop_and_redirect->($self, CLASS_KEY, 1);
    } else {
        $pop_and_redirect->($self, CLASS_KEY, 0);
    }
};

$handle_bulk_save = sub {
    my ($self) = @_;
    my $param = $self->request_args;

    my $state_name = get_state_name(CLASS_KEY);

    if ($state_name eq 'edit_bulk') {
        $split_fields->(CLASS_KEY, $param->{CLASS_KEY.'|text'});
        $save_data->(CLASS_KEY);
        my $data_field = get_state_data(CLASS_KEY, 'field');
        my $arg = "&quot;$data_field&quot;";
        add_msg($self->lang->maketext("[_1] Elements saved.", $arg));
    } else {
        $split_super_bulk->($self, $param->{CLASS_KEY.'|text'});
        unless (num_msg() > 0) {
            $super_save_data->($self);
        }
    }
};

#------------------------------------------------------------------------------#
# super_save_data
#
# Like save_data above, but recognize the POD style commands that allow the user
# to specify what element goes with each chunk of text

$super_save_data = sub {
    my ($self) = @_;
    my $widget = CLASS_KEY;

    # The tile currently being edited by container_prof
    my $tile   = get_state_data($widget, 'tile');
    my $at     = $tile->get_element;
    # The field within the tile being edited via bulk edit
    my $field  = get_state_data($widget, 'field');
    # Data tiles already created while editing the field in bulk_edit
    my $dtiles = get_state_data($widget, 'dtiles') || [];
    # The most recent data entered into bulk edit
    my $data   = get_state_data($widget, 'data');

    # Arrange these tiles by type
    my $tpool;
    while (my $t = shift @$dtiles) {
        push @{$tpool->{$t->get_key_name}}, $t;
    }

    # Fill the data into the objects in our tpool
    foreach my $d (@$data) {
        my ($name, $text) = @$d;

        my $t;
        # If we have an existing object with this name, then use it
        if ($tpool->{$name} and scalar(@{$tpool->{$name}})) {
            $t = shift @{$tpool->{$name}};
        }
        # If there is no object then create one
        else {
            my ($atc, $atd);
            if ($atd = $at->get_data($name)) {
                $t = Bric::Biz::Asset::Business::Parts::Tile::Data->new
                  ({ 'element_data' => $atd,
                     'object_type'  => 'story' });
        } else {
                $atc = $at->get_containers($name);

                $t = Bric::Biz::Asset::Business::Parts::Tile::Container->new({
                    'element'     => $atc,
                    'object_type' => 'story'
                });
            }

            # Add this new tile.
            $tile->add_tile($t);
        }

        # Don't update the contents of containers, just data the elements
        $t->set_data($text) unless $t->is_container;

        push @$dtiles, $t;
    }

    # Delete any remaining tiles that haven't been filled.
    while (my ($n,$p) = each %$tpool) {
        next unless $p and scalar(@$p);

        if ($p->[0]->is_container) {
            my $msg = 'Note: Container element [_1] removed '
              . 'in bulk edit but will not be deleted.';
            add_msg($self->lang->maketext($msg, "'$n'"));
            # Put these container tiles back in the list
            push @$dtiles, @$p;
            next;
        } else {
            my $atd = $at->get_data($n);

            if ($atd->get_required()) {
                unless (grep { $_->get_key_name eq $n } @$dtiles) {
                    my $msg = 'Note: Data element [_1] is required and cannot '
                      . 'be completely removed.  Will delete all but one';
                    add_msg($self->lang->maketext($msg, "'$n'"));
                    push @$dtiles, shift @$p;
                }
            }
        }
        $tile->delete_tiles($p) if scalar(@$p);
    }

    $tile->reorder_tiles($dtiles) if $dtiles;

    # Save the tile
    $tile->save;

    set_state_data($widget, 'dtiles', $dtiles);
};

#------------------------------------------------------------------------------#
# split_fields
#
# Splits a bulk edit text area into chunks based on the separator the user has
# choosen.  The default separator is "\n\n".

$split_fields = sub {
    my ($widget, $text) = @_;
    my $sep = get_state_data($widget, 'separator');
    my @data;

    # Change Windows newlines to Unix newlines.
    $text =~ s/\r\n/\n/g;

    # Grab the split regex.
    my $re = $regex->{$sep} ||= qr/\s*\Q$sep\E\s*/;

    # Split 'em up.
    @data = map { s/^\s+//;         # Strip out beginning spaces.
                  s/\s+$//;         # Strip out ending spaces.
                  s/[\n\t\r\f]/ /g; # Strip out unwanted characters.
                  s/\s{2,}/ /g;     # Strip out double-spaces.
                  $_;
              } split(/$re/, $text);

    # Save 'em.
    set_state_data($widget, 'data', \@data);
};

#------------------------------------------------------------------------------#
# compare_soundex
#
# Compare two words using the Soundex algorithm and then subtracting the result
# to find the nearest matching word.

$compare_soundex = sub {
    my ($a, $b) = @_;

    ($a, $b) = Text::Soundex::soundex($a, $b);

    return (abs(ord(substr($a, 0, 1)) - ord(substr($b, 0, 1))) +
            abs((substr($a, 1, 1)) - (substr($b, 1, 1))) +
            abs((substr($a, 2, 1)) - (substr($b, 2, 1))) +
            abs((substr($a, 3, 1)) - (substr($b, 3, 1))))
};

#------------------------------------------------------------------------------#
# compare_levenshtein
#
# Compare two words using the levenshtein algorithm which returns a single
# comparable number.

$compare_levenshtein = sub {
    my ($a, $b) = @_;
    return Text::Levenshtein::distance($a, $b);
};

#------------------------------------------------------------------------------#
# compare
#
# Alias to the comparison method to use.  First check for Text::levenshtein and
# then the less effective Text::Soundex

$compare = $Text::Levenshtein::VERSION ? $compare_levenshtein : $compare_soundex;

#------------------------------------------------------------------------------#
# closest
#
# Given a list of words and a target word, return the word from the list that
# most closely matches the target word.

$closest = sub {
    my ($words, $w) = @_;
    my ($lowest, $score);

    foreach my $test_word (@$words) {
        my $cur_score = $compare->($test_word, $w);

        if ((not defined $score) or ($cur_score < $score)) {
            $score  = $cur_score;
            $lowest = $test_word;
        }
    }

    return $lowest;
};

#------------------------------------------------------------------------------#
# split_super_bulk
#
# Splits out chunks of text from the bulk edit textarea box as well as the
# element name associated with it

$split_super_bulk = sub {
    my ($self, $text) = @_;
    my $widget = CLASS_KEY;

    # Get the tile so we can figure out what the repeatable elements are
    my $tile      = get_state_data($widget, 'tile');
    my $at        = $tile->get_element;
    my %poss_names;

    # Get the default data type
    my $def_field = get_state_data('_tmp_prefs',
                                   'container_prof.' . $at->get_id . '.def_field');

    # Create hash of possible names from the data elements
    foreach my $p ($at->get_data) {
        print STDERR $p->get_key_name, "\n";
        $poss_names{$p->get_key_name} = 'd';
    }

    # Add to the hash of possible names with container elements
    foreach my $p ($at->get_containers) {
        $poss_names{$p->get_key_name} = 'c';
    }

    # A checked text accumulator, and the element type for that text
    my ($acc, $type);

    # Check each line of the text
    my @chunks;
    my %seen;
    my $blanks = 0;

    foreach my $l (split(/\r?\n|\r/, $text)) {
        chomp($l);

        # See if we have a blank line
        if ($l =~ /^\s*$/) {
            $blanks++;

            # If we have any accumulated text or if we have more than two
            # blank lines in a row, then save it off
            if ($acc or ($blanks > 1)) {
                $type = $def_field if not $type;
                push @chunks, [$type, $acc];
                $acc  = '';
                $type = '';
                $blanks = 0;
            }
        }
        # This line starts with a '=' marking a new element
        elsif ($l =~ /^=(\S+)\s*$/) {
            # If someone neglects to add a double space after a data element
            # with no content, make sure not to delete that element.  We can
            # only do this when the two fields involved are not the default
            # field and are explicitly listed using the '=tag' syntax.
            if ($type) {
                push @chunks, [$type, $acc];
            }

            $type = $1;

            # See if this field is repeatable.
            my $repeatable;
            if (my $atd = $at->get_data($type)) {
                $repeatable = $atd->get_quantifier || 0;
            } elsif (my $atc = $at->get_containers($type)) {
                # Containers are currently always repeatable
                $repeatable = 1;    #$at->is_repeatable($atc) || 0;
            }

            # If this field is not repeatable and we already have one of these
            # fields, then complain to the user
            if (not $repeatable and $seen{$type}) {
                my $msg = 'Field [_1] appears more than once but it is not a '
                  . 'repeatable element.  Please remove all but one.';
                add_msg($self->lang->maketext($msg, "'$type'"));
                return;
            }

            # Note that we've seen this element type
            $seen{$type} = 1;

            if (not exists $poss_names{$type}) {
                my $new_type = $closest->([keys %poss_names], $type);
                my $msg = 'Bad element name [_1]. Did you mean [_2]?';
                add_msg($self->lang->maketext($msg, "'$type'", "'$new_type'"));
            }

            # If this is a container field, then reset everything
            if ($poss_names{$type} eq 'c') {
                push @chunks, [$type, $acc];
                $acc  = '';
                $type = '';
            }

            $blanks = 0;
        }
        # Nothing special about this line, push it into the accumulator
        else {
            $type ||= $def_field || $chunks[-1]->[0];
            $acc .= $acc ? " $l" : $l;
            $blanks = 0;
        }
    }

    # Add any leftover data
    if ($acc or $type) {
        $type = $def_field if not $type;

        push @chunks, [$type, $acc];
    }

    set_state_data($widget, 'data', \@chunks);
};


###

$drift_correction = sub {
    my ($self) = @_;
    my $param = $self->request_args;

    # Don't do anything if we've already corrected ourselves.
    return if $param->{'_drift_corrected_'};

    # Update the state name
    set_state_name(CLASS_KEY, $param->{CLASS_KEY.'|state_name'});

    # Get the tile ID this page thinks its displaying.
    my $tile_id = $param->{CLASS_KEY.'|top_stack_tile_id'};

    # Return if the page doesn't send us a tile_id
    return unless $tile_id;

    my $tile  = get_state_data(CLASS_KEY, 'tile');
    # Return immediately if everything is already in sync.
    if ($tile->get_id == $tile_id) {
        $param->{'_drift_corrected_'} = 1;
        return;
    }

    my $stack = get_state_data(CLASS_KEY, 'tiles');
    my @tmp_stack;

    while (@$stack > 0) {
        # Get the next tile on the stack.
        $tile = pop @$stack;
        # Finish this loop if we find our tile.
        last if $tile->get_id == $tile_id;
        # Push this tile on our temp stack just in case we can't find our ID.
        unshift @tmp_stack, $tile;
        # Undef the tile since its not the one we're looking for.
        $tile = undef;
    }

    # If we found the tile, make it the head tile and save the remaining stack.
    if ($tile) {
        set_state_data(CLASS_KEY, 'tile', $tile);
        set_state_data(CLASS_KEY, 'tiles', $stack);
    }
    # If we didn't find the tile, abort, and restore the tile stack
    else {
        add_msg("Warning! State inconsistent: Please use the buttons provided "
                ."by the application rather than the 'Back'/'Forward' buttons");

        # Set this flag so that nothing gets changed on this request.
        $param->{'_inconsistent_state_'} = 1;

        set_state_data(CLASS_KEY, 'tiles', \@tmp_stack);
    }

    # Drift has now been corrected.
    $param->{'_drift_corrected_'} = 1;
};


1;
