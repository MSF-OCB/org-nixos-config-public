import getopt
import json
import sys
from pathlib import Path
import os


def main() -> None:
    # Open the JSON file
    root_dir = Path(__file__).resolve().parent.parent.parent
    f = open(root_dir / "org-config/json/users.json")

    # Create a list of arguments without the name of the script
    argv = sys.argv[1:]
    # Set the short options we are expecting (i.e -h or -v)
    short_opts = "ho:"
    # Set the long options we are expecting (i.e --help or value=)
    long_opts = ["help", "outdir="]

    # Pass the argument list to getopt along with the options we are expecting
    try:
        args, opts = getopt.getopt(argv, short_opts, long_opts)
    except getopt.error as err:
        print(str(err))

    outdir = None

    for current_argument, current_value in args:
        if current_argument in ("-h", "--help"):
            print(
                "Usage: dump_roles_for_audit.py -o/--outdir <dir>, where dir is the where the CSV files will be put"
            )
            exit()
        elif current_argument in ("-o", "--outdir"):
            outdir = current_value

    if not outdir:
        print("Output directory not specified")
        exit()

    outdir_path = Path(outdir)

    if not outdir_path.exists() or not outdir_path.is_dir():
        print("Output directory does not exist or not a directory")
        exit()

    data = json.load(f)

    users = set()

    roles = set()

    hosts = set()

    privs = set()

    user_host_privs = dict()
    role_hosts = dict()
    host_roles = dict()
    role_user_privs = dict()
    role_roles = dict()

    #
    # Part A. Read the JSON file into the above Python data structures
    #

    #
    # 1. Process all per-host configuration
    #

    for host, enabled in data["users"]["per-host"].items():
        hosts.add(host)

        #
        # 1.1 Process all privs enabled for a specific user for each host
        #

        if "enable" in enabled:
            for user, priv in enabled["enable"].items():
                users.add(user)
                privs.add(priv)

                if user not in user_host_privs:
                    user_host_privs[user] = dict()

                user_host_privs[user][host] = priv

                # print(host+"\t"+user+"\t"+priv)

        #
        # 1.2 Process all roles enabled for each host
        #

        if "enable_roles" in enabled:
            for role in enabled["enable_roles"]:
                if role not in role_hosts:
                    role_hosts[role] = set()

                role_hosts[role].add(host)

                if host not in host_roles:
                    host_roles[host] = set()

                host_roles[host].add(role)

                roles.add(role)

                # print(host + "\t"+role)

    #
    # 2. Process all role configurations
    #

    for role, enabled in data["users"]["roles"].items():
        roles.add(role)

        #
        # 2.1 Process all privs enabled for a specific user for each role
        #

        if "enable" in enabled:
            for user, priv in enabled["enable"].items():
                users.add(user)
                privs.add(priv)

                if role not in role_user_privs:
                    role_user_privs[role] = dict()

                role_user_privs[role][user] = priv

                # print(role+"\t"+user+"\t"+priv);

    #
    # Use a separate loop so we have the complete roleUserPrivs mapping before we expand out the roleUserPrivs
    #

    for role, enabled in data["users"]["roles"].items():
        roles.add(role)

        #
        # 2.2. Process all roles that are enabled via other roles
        #

        if "enable_roles" in enabled:
            for enabled_role in enabled["enable_roles"]:
                roles.add(enabled_role)

                if role not in role_roles:
                    role_roles[role] = set()

                role_roles[role].add(enabled_role)

                #
                # 2.3. Expand out the roleUserPrivs
                #

                for user, priv in role_user_privs[enabled_role].items():
                    if role not in role_user_privs:
                        role_user_privs[role] = dict()

                    role_user_privs[role][user] = priv

                # print(role+"\t"+enabled_role);

    # print("users="+str(sorted(users)))
    # print("roles="+str(roles))
    # print("hosts="+str(hosts))
    # print("privs="+str(privs))

    # print("userHostPrivs="+str(userHostPrivs))
    # print("roleHosts="+str(roleHosts))
    # print("roleUserPrivs="+str(roleUserPrivs))
    # print("roleRoles="+str(roleRoles))

    #
    # Part B. Write CSV files in a way we can import them into XLS
    #

    #
    # Direct user privileges PER HOST
    #

    duhp = open(outdir_path / "direct_user_host_privs.csv", "w", encoding="UTF-8")

    duhp.write("User ↓ Host →,")

    for host in sorted(hosts):
        duhp.write(host + ",")

    duhp.write("\n")

    for user in sorted(users):
        duhp.write(user + ",")

        for host in sorted(hosts):
            if user in user_host_privs and host in user_host_privs[user]:
                duhp.write(user_host_privs[user][host])

            duhp.write(",")

        duhp.write("\n")

    duhp.close()

    #
    # Roles PER HOST
    #

    rhp = open(outdir_path / "role_host_enabled.csv", "w", encoding="utf-8")

    rhp.write("Server ↓ Role →,")

    for role in sorted(roles):
        rhp.write(role + ",")

    rhp.write("\n")

    for host in sorted(hosts):
        rhp.write(host + ",")

        for role in sorted(roles):
            if role in role_hosts and host in role_hosts[role]:
                rhp.write("enabled")

            rhp.write(",")

        rhp.write("\n")

    rhp.close()

    #
    # User privs PER ROLE
    #

    rpr = open(outdir_path / "users_privs_per_role.csv", "w", encoding="utf-8")

    rpr.write("User ↓ Role →,")

    for user in sorted(users):
        rpr.write(user + ",")

    rpr.write("\n")

    for role in sorted(roles):
        rpr.write(role + ",")

        for user in sorted(users):
            if role in role_user_privs and user in role_user_privs[role]:
                rpr.write(role_user_privs[role][user])

            rpr.write(",")

        rpr.write("\n")

    rpr.close()

    #
    # Effective user privileges PER HOST
    #

    euhp = open(outdir_path / "effective_user_host_privs.csv", "w", encoding="utf-8")

    euhp.write("User ↓ Host →,")

    for host in sorted(hosts):
        euhp.write(host + ",")

    euhp.write("\n")

    for user in sorted(users):
        euhp.write(user + ",")

        for host in sorted(hosts):
            if user in user_host_privs and host in user_host_privs[user]:
                euhp.write(user_host_privs[user][host])
            elif host in host_roles:
                roles_for_this_user_host = set()
                for role in host_roles[host]:
                    if role in role_user_privs and user in role_user_privs[role]:
                        roles_for_this_user_host.add(role_user_privs[role][user])

                if len(roles_for_this_user_host) == 1:
                    euhp.write(roles_for_this_user_host.pop())

                elif len(roles_for_this_user_host) > 1:
                    raise Exception(
                        "user " + user + " has too many roles for the host" + host
                    )

            euhp.write(",")

        euhp.write("\n")

    euhp.close()


if __name__ == "__main__":
    main()
