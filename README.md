    show/believe              List nodes that a given node considers as "believable"

    Console.pm                Customisation of console colours in Linux

    DXDebug.pm                &Local::log_msg

    DXLog.pm                  &Local::log_msg

    DXVars.pm                 Inclusion of id & token for Telegram Bot and e-mail settings

    Filter.pm                 Reload user filters

    Local.pm                  Added mqtt, rbn spots, rbn_quality spots, log_msg,
                              user connections/disconnections and telegram

    RBN.pm		          Send info to Local.pm and regex filter for zones

    check_build.pl		  Check and install if there is a new build Mojo
                              Send a message via Telegram bot
			      
    compression.pl            Compression of the previous day's debug files

    conndisc.pl               Reports connections/disconnections or attempted connections to or from nodes.

    show/list_pc92_nodes      Show nodes seen via PC92

    mnodes.pl		  List of connected nodes for use from a mobile app

					Callsign  R P  Type       Connection Time
					--------  - -  ---------  ---------------
					EA4URE-5  R P  NODE DXSP   1 d  2 h  22 m
					G4ELI-9   R P  NODE DXSP   1 d  2 h  22 m
					VE7CC-1        NODE DXSP   0 d  7 h   7 m

    musers.pl                 List of connected users for use from a mobile app

					Callsign  R P  Type       Connection Time
					--------  - -  ---------  ---------------
					CT7ARQ         USER EXT    0 d  8 h  29 m
					EA1BHB         USER EXT    0 d  7 h  13 m
					SK0MMR         USER RBN    1 d  2 h  23 m
					SK1MMR         USER RBN    1 d  2 h  23 m

    msg_sysop.pl              Send message to sysop via Telegram 

    show/typenodes            Search for nodes by type in the DB

    show/registered           Modification of the original command

    send_pc92.pl              Utility that informs the rest of the network about the status of the node

    search.pl                 Utility that search debug by string(s) and a human time range.
    
    summary.pl                Utility that displays a summary of node data
    
    total.pl                  Total Nodes/Users sent to the Telegram bot

					EA3CV-2   ➡️  Nodes: 14   Users: 35

    total_conn.pl             Calculates the connection time per user in the current year

					Call       Connected  Spots  Total Time
					---------  ---------  -----  --------------------
					EA3GOP     87         0       28 d 08 h 44 m 09 s
					EA3HLM     288        6       19 d 09 h 36 m 04 s
					EA5JN      33         169     17 d 13 h 54 m 15 s
					KC1CAB     56         0       12 d 23 h 10 m 16 s
     
    total_frames.pl           Utility to count IN/OUT frames per node

    update_ip.pl              Updating the $main::localhost_alias_ipv4 and @main::localhost_names var

    undo_newbuild.pl          Revert to the version before the update. Mojo branch only

    unset/badip.pl            Remove IPs from the badip file

    view_dupes.pl             Search for a string in dupefile  

    who.pl                    Another way to view the list of connected stations

    set/regpass.pl            Unify the registration + password process in a single command

    spots_node.pl             Utility to see the origin and quantity of spots per day.

    send_spot.exe             Sending FT8 Spots without mobile coverage using send_spot.exe
    
    unset/regpass.pl          Unify the unregistration + unpassword process in a single command

    Docs                      Documents contributed to the DXSpider Wiki:

				  Configure Node with more than one local IP.pdf
				  Configure node with Dynamic IP.pdf
				  Create a secure connection between nodes.pdf
				  How to set up a partner node in dxcluster
				  List of nodes for mobile use.pdf
				  List of users for mobile use.pdf
				  Network Latency Measurements in the DXCluster Node Network
				  Node_configuration_for_user_access.pdf
				  Restoring the user DB.pdf
				  HowTo send_spot with FT8 Spots without Mobile Coverage 
