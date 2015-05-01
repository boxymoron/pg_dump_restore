#!/bin/bash

sourceDbName=""
sourceSchema="schemaA"
sourceHost="localhost"
sourceUser=""
sourcePassword=""

destDbName=""
destSchema="schemaB"
destHost="localhost"
destUser=""
destPassword=""

outputDir="/tmp/dump"

mkdir ${outputDir}

dropObjects=false
recreateSequences=false
recreateTriggers=false
tables="a space delimited list of table names without a schema prefix"

###################################################################################################
echo "You are about to dump and restore a database, this may trash an existing system if parameters are incorrect. Please review the following parameters:"
echo "Source: host: ${sourceHost}, database: ${sourceDbName}, schema:${sourceSchema}, user: ${sourceUser}"
echo "Destination: host: ${destHost}, database: ${destDbName}, schema:${destSchema}, user: ${destUser}"
if [[ ${recreateSequences} = true ]]; then 
	echo "All SEQUENCES will be recreated." 
else 
	echo "SEQUENCES will not be recreated." 
fi
if [[ ${recreateTriggers} = true ]]; then 
	echo "All FUNCTIONS and TRIGGERS will be recreated." 
else 
	echo "FUNCTIONS and TRIGGERS will not be recreated" 
fi
if [[ ${dropObjects} ]]; then 
	echo "The following TABLES will be DROPPED recreated in the destination: ${tables}" 
else 
	echo "The following tables will be created: ${tables}" 
fi

echo -n "Would you like to proceed? y/n: "
read yesNo
if [[ "${yesNo}" =~ ^[Nn]$   ]]; then
	echo "Exiting."
	exit
fi

###################################################################################################

if [[ ${recreateSequences} = true ]]; then
	echo "Dumping Sequences"
	psql --no-align --tuples-only --quiet -c "SELECT sequence_name FROM information_schema.sequences where sequence_schema ="$'\''"${sourceSchema}"$'\''";" -o "${outputDir}/sequence.list"
	if [ $? -ne 0 ]; then
		echo "Master SEQUENCE query failed. Exiting."
		exit 1
	fi
	
	while read pg_sequence ; do
		
		echo "Dumping Sequence: ${pg_sequence}"
		dump_file="${sourceSchema}-${pg_sequence}.sql"
		
		if [[ ${dropObjects} = true ]]; then
			psql --dbname="${destDbName}" --host="${destHost}" -U "${destUser}" -c "DROP SEQUENCE ${destSchema}.${pg_sequence} ;"
		fi
		
#do not try to indent this as it will break!
query=`cat <<EOF
	DROP SEQUENCE IF EXISTS destSchema.repl_seq;
	SELECT 'CREATE SEQUENCE destSchema.'|| pg_sequences.sequence_name || ' INCREMENT ' || increment_by || ' MINVALUE ' || min_value || ' MAXVALUE ' || max_value || ' START ' || last_value || ' CACHE ' || cache_value 
	|| '; ALTER TABLE destSchema.repl_seq OWNER TO public; GRANT SELECT, USAGE ON TABLE destSchema.repl_seq TO public; '
	FROM information_schema.sequences pg_sequences,
	sourceSchema.repl_seq
	where pg_sequences.sequence_schema ='sourceSchema'
	AND pg_sequences.sequence_name = 'repl_seq';
EOF
`
		query=$(echo ${query} | sed -e "s/destSchema/${destSchema}/g" | sed -e "s/sourceSchema/${sourceSchema}/g" | sed -e "s/repl_seq/${pg_sequence}/g")
		
		query=$(psql --no-align --tuples-only --quiet -c "${query}")
		if [ $? -ne 0 ]; then
			echo "Sequence prepare query failed. Exiting."
			exit 1
		fi
		
		psql --no-align --tuples-only --quiet -c "${query}"
		if [ $? -ne 0 ]; then
			echo "Sequence create query failed. Exiting."
			exit 1
		fi
	done < "${outputDir}/sequence.list"
fi

if [[ ${recreateTriggers} = true ]]; then
	psql --no-align --tuples-only --quiet -c \
		"select tgname from pg_trigger where tgisinternal = false UNION select proname from pg_proc where pronamespace=(select oid from pg_namespace where nspname="$'\''"${sourceSchema}"$'\''");" -o "${outputDir}/triggers.list"
	
	if [ $? -ne 0 ]; then
			echo "Master TRIGGER/FUNCTION query failed. Exiting."
			exit 1
	fi
	
	while read pg_function ; do
	
		echo "Dumping TRIGGER/FUNCTION: ${pg_function}"
		
		dump_file="${sourceSchema}-${pg_function}.sql"
		
		psql --no-align --tuples-only --quiet -c "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname="$'\''"${pg_function}"$'\''" AND \
			pronamespace=(SELECT oid FROM pg_namespace WHERE nspname="$'\''"${sourceSchema}"$'\''");" "${sourceDbName}" \
			-o "${outputDir}/${dump_file}";
		
		if [ $? -ne 0 ]; then
			echo "Dump TRIGGER query failed. Exiting."
			exit 1
		fi
		
		if [[ ${dropObjects} = true ]]; then
			psql --dbname="${destDbName}" --host="${destHost}" -U "${destUser}" -c "DROP FUNCTION ${destSchema}.${pg_function} ;"
			if [ $? -ne 0 ]; then
				psql --dbname="${destDbName}" --host="${destHost}" -U "${destUser}" -c "DROP TRIGGER ${destSchema}.${pg_function} ;"
				if [ $? -ne 0 ]; then
					echo "DROP FUNCTION/TRIGGER failed for : ${pg_function}"
				fi
			fi
		fi
		
		echo "SET search_path = ${destSchema};" > ${outputDir}/${dump_file}.tmp
		
		cat ${outputDir}/${dump_file} | \
			sed -e 's/^SET .*//' | \
			sed -e 's/^--.*//' | \
			sed -e 's/^$//' | \
			sed -e "s/${sourceSchema}/${destSchema}/g" \
			>> ${outputDir}/${dump_file}.tmp
		
		echo "Restoring Trigger: ${pg_function}"
		
		psql --dbname="${destDbName}" --host="${destHost}" -U "${destUser}" --file="${outputDir}/${dump_file}.tmp"
		if [ $? -ne 0 ]; then
			echo "Create TRIGGER query failed. Exiting."
			exit 1
		fi
		
	done < "${outputDir}/triggers.list"
	
else

	echo "Not recreating functions and triggers"
	
fi

#move tables around
for table in ${tables} ; do
	echo "Dumping from host: $sourceHost, database: $sourceDbName,  table: $sourceSchema.$table"
	dump_file="${sourceSchema}-${table}.sql"
	pg_dump -C -O --schema=\"${sourceSchema}\" --table=\"${sourceSchema}\".\"${table}\" --dbname="${sourceDbName}" --host="${sourceHost}" -U "${sourceUser}" --inserts --file "${outputDir}/${dump_file}"
	if [ $? -ne 0 ]; then
		echo "Master TABLE query failed. Exiting."
		exit 1
	fi
	
	echo "Restoring ${table} to ${destHost}/${destDbName}"
		
	echo "SET search_path = ${destSchema};" > ${outputDir}/${dump_file}.tmp
	
	if [[ ${dropObjects} = true ]]; then
		echo "DROP TABLE IF EXISTS ${destSchema}.${table} CASCADE;" >> ${outputDir}/${dump_file}.tmp
	fi
		
	cat ${outputDir}/${dump_file} | \
		sed -e 's/^SET .*//' | \
		sed -e 's/^--.*//' | \
		sed -e 's/^$//' \
		>> ${outputDir}/${dump_file}.tmp
	
	psql -h "${destHost}" -d "${destDbName}" -U "${destUser}" -f "${outputDir}/${dump_file}.tmp"
	
	if [ $? -ne 0 ]; then
		echo "Create TABLE query failed. Exiting."
		exit 1
	fi
	
done
