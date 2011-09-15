package Hydra::Controller::API;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;
use Hydra::Helper::CatalystUtils;
use Hydra::Controller::Project;
use JSON::Any;
use DateTime;
use Digest::SHA qw(sha256_hex);

# !!! Rewrite this to use View::JSON.

sub api : Chained('/') PathPart('api') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
}

sub projectToHash {
    my ($project) = @_;
    return {
        name => $project->name,
        description => $project->description
    }; 
}

sub projects : Chained('api') PathPart('projects') Args(0) {
    my ($self, $c) = @_;
    
    my @projects = $c->model('DB::Projects')->search({hidden => 0}, {order_by => 'name'}) ;

    my @list ;
    foreach my $p (@projects) {
      push @list, projectToHash($p) ;
    }
    
    $c->stash->{'plain'} = { 
        data => scalar (JSON::Any->objToJson(\@list)) 
    };
    $c->forward('Hydra::View::Plain');
}

sub buildToHash {
    my ($build) = @_;
    my $result = {
        id => $build->id,
        project => $build->get_column("project"),
        jobset => $build->get_column("jobset"),
        job => $build->get_column("job"),
        system => $build->system,
        nixname => $build->nixname,
        finished => $build->finished,
        timestamp => $build->timestamp
    };

    if($build->finished) {    
        $result->{'buildstatus'} = $build->get_column("buildstatus") ;
    } else {
        $result->{'busy'} = $build->get_column("busy");
        $result->{'priority'} = $build->get_column("priority");
    }
    
    return $result;
};

sub latestbuilds : Chained('api') PathPart('latestbuilds') Args(0) {
    my ($self, $c) = @_;
    my $nr = $c->request->params->{nr} ;
    error($c, "Parameter not defined!") if !defined $nr;

    my $project = $c->request->params->{project} ;
    my $jobset = $c->request->params->{jobset} ;
    my $job = $c->request->params->{job} ;
    my $system = $c->request->params->{system} ;
    
    my $filter = {finished => 1} ;
    $filter->{project} = $project if ! $project eq ""; 
    $filter->{jobset} = $jobset if ! $jobset eq ""; 
    $filter->{job} = $job if !$job eq ""; 
    $filter->{system} = $system if !$system eq ""; 
    
    my @latest = joinWithResultInfo($c, $c->model('DB::Builds'))->search($filter, {rows => $nr, order_by => ["timestamp DESC"] });
    
    my @list ;
    foreach my $b (@latest) {
      push @list, buildToHash($b) ;
    }
    
    $c->stash->{'plain'} = { 
        data => scalar (JSON::Any->objToJson(\@list)) 
    };
    $c->forward('Hydra::View::Plain');
}

sub jobsetToHash {
    my ($jobset) = @_;
    return {
    	project => $jobset->project->name,
    	name => $jobset->name,
        nrscheduled => $jobset->get_column("nrscheduled"),
        nrsucceeded => $jobset->get_column("nrsucceeded"),
        nrfailed => $jobset->get_column("nrfailed"),
        nrtotal => $jobset->get_column("nrtotal")
    };
} 

sub jobsets : Chained('api') PathPart('jobsets') Args(0) {
    my ($self, $c) = @_;

    my $projectName = $c->request->params->{project} ;
    error($c, "Parameter 'project' not defined!") if !defined $projectName;

    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    my @jobsets = jobsetOverview($c, $project);
    
    my @list ;
    foreach my $j (@jobsets) {
      push @list, jobsetToHash($j) ;
    }
    
    $c->stash->{'plain'} = { 
        data => scalar (JSON::Any->objToJson(\@list)) 
    };
    $c->forward('Hydra::View::Plain');
}

sub queue : Chained('api') PathPart('queue') Args(0) {
    my ($self, $c) = @_;

    my $nr = $c->request->params->{nr} ;
    error($c, "Parameter not defined!") if !defined $nr;

    my @builds = $c->model('DB::Builds')->search({finished => 0}, {rows => $nr, join => ['schedulingInfo'] , order_by => ["busy DESC", "priority DESC", "timestamp"], '+select' => ['schedulingInfo.priority', 'schedulingInfo.busy'], '+as' => ['priority', 'busy']  });
    
    my @list ;
    foreach my $b (@builds) {
      push @list, buildToHash($b) ;
    }
       
    $c->stash->{'plain'} = { 
        data => scalar (JSON::Any->objToJson(\@list)) 
    };
    $c->forward('Hydra::View::Plain');
}

sub nrqueue : Chained('api') PathPart('nrqueue') Args(0) {
    my ($self, $c) = @_;
    my $nrQueuedBuilds = $c->model('DB::BuildSchedulingInfo')->count();
    $c->stash->{'plain'} = { 
        data => " $nrQueuedBuilds"
    };
    $c->forward('Hydra::View::Plain');
}

sub nrrunning : Chained('api') PathPart('nrrunning') Args(0) {
    my ($self, $c) = @_;
    my $nrRunningBuilds = $c->model('DB::BuildSchedulingInfo')->search({ busy => 1 }, {})->count();
    $c->stash->{'plain'} = { 
        data => " $nrRunningBuilds"
    };
    $c->forward('Hydra::View::Plain');
}

sub nrbuilds : Chained('api') PathPart('nrbuilds') Args(0) {
    my ($self, $c) = @_;
    my $nr = $c->request->params->{nr} ;
    my $period = $c->request->params->{period} ;
    
    error($c, "Parameter not defined!") if !defined $nr || !defined $period;
    my $base;

    my $project = $c->request->params->{project} ;
    my $jobset = $c->request->params->{jobset} ;
    my $job = $c->request->params->{job} ;
    my $system = $c->request->params->{system} ;

    my $filter = {finished => 1} ;
    $filter->{project} = $project if ! $project eq ""; 
    $filter->{jobset} = $jobset if ! $jobset eq ""; 
    $filter->{job} = $job if !$job eq ""; 
    $filter->{system} = $system if !$system eq ""; 

    $base = 60*60 if($period eq "hour");
    $base = 24*60*60 if($period eq "day");
    
    my @stats = $c->model('DB::Builds')->search($filter, {select => ["count(*)"], as => ["nr"], group_by => ["timestamp - timestamp % $base"], order_by => "timestamp - timestamp % $base DESC", rows => $nr}) ;
    my @arr ;
    foreach my $d (@stats) {
	  push @arr, int($d->get_column("nr"));
    }
    @arr = reverse(@arr);
    
    $c->stash->{'plain'} = { 
        data => scalar (JSON::Any->objToJson(\@arr)) 
    };
    $c->forward('Hydra::View::Plain');
}

sub scmdiff : Chained('api') PathPart('scmdiff') Args(0) {
    my ($self, $c) = @_;

    my $uri = $c->request->params->{uri} ;
    my $type = $c->request->params->{type} ;
    my $branch = $c->request->params->{branch} ;
    my $rev1 = $c->request->params->{rev1} ;
    my $rev2 = $c->request->params->{rev2} ;

    my $diff = "";
    if($type eq "hg") {
        my $clonePath = scmPath . "/" . sha256_hex($uri);
        die if ! -d $clonePath;
	$diff .= `(cd $clonePath ; hg log -r $rev1:$rev2)`;
	$diff .= `(cd $clonePath ; hg diff -r $rev1:$rev2)`;
    } elsif ($type eq "git") {
        my $clonePath = scmPath . "/" . sha256_hex($uri.$branch);
        die if ! -d $clonePath;
	$diff .= `(cd $clonePath ; git log $rev1..$rev2)`;
	$diff .= `(cd $clonePath ; git diff $rev1..$rev2)`;
    }

    $c->stash->{'plain'} = { data => (scalar $diff) || " " };
    $c->forward('Hydra::View::Plain');
}

1;
