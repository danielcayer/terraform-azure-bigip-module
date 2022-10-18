ssh -i ~/.ssh/id_rsa_azure -tt azops@20.104.250.149 'echo y | tmsh -q revoke sys license 2>/dev/null'
