<%doc>

A quick tool to clear cache

</%doc>


<%init>

%HTML::Mason::Commands::session = ();

</%init>

<html>

<body>

Should be cleared

<& '/widgets/debug/debug.mc' &>


</body>

</html>
