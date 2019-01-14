#!/usr/bin/env bats

load ../_common/helpers

# CEGA_CONNECTION and CEGA_USERS_CREDS should be already set,
# when this script runs

function setup() {

    # Defining the TMP dir
    TESTFILES=${BATS_TEST_FILENAME}.d
    mkdir -p "$TESTFILES"

    # Test user
    TESTUSER=dummy

    # Utilities to scan the Message Queues
    MQ_FIND="python ${MAIN_REPO}/extras/rabbitmq/find.py --connection ${CEGA_CONNECTION}"
    MQ_GET="python ${MAIN_REPO}/extras/rabbitmq/get.py --connection ${CEGA_CONNECTION}"
    MQ_PUBLISH="python ${MAIN_REPO}/extras/rabbitmq/publish.py --connection ${CEGA_CONNECTION}"

    # Find inbox port mapping. Usually 2222:9000
    legarun docker port inbox 9000
    [ "$status" -eq 0 ]
    INBOX_PORT=${output##*:}
    LEGA_SFTP="sftp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -P $INBOX_PORT"
}

function teardown() {
    rm -rf ${TESTFILES}
}

# MQ federated queue
# ------------------
# Message published at Central EGA but local broker down for a while
# When restarted, no messages are lost

@test "MQ federation" {
    skip "Used after the update for MQ connection retries"
    
    TESTFILE=$(uuidgen)

    # Create a random file of {size} MB
    legarun dd if=/dev/urandom of=${TESTFILES}/${TESTFILE} count=1 bs=1048576
    [ "$status" -eq 0 ]

    # Encrypt it in the Crypt4GH format
    legarun lega-cryptor encrypt --pk ${EGA_PUB_KEY} -i ${TESTFILES}/${TESTFILE} -o ${TESTFILES}/${TESTFILE}.c4ga
    [ "$status" -eq 0 ]

    # Upload it
    legarun ${LEGA_SFTP} -i ${TESTDATA_DIR}/${TESTUSER}.sec ${TESTUSER}@localhost <<< $"put ${TESTFILES}/${TESTFILE}.c4ga /${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]

    # Fetch the correlation id for that file (Hint: with user/filepath combination)
    retry_until 0 100 1 ${MQ_GET} v1.files.inbox "${TESTUSER}" "/${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]
    CORRELATION_ID=$output

    # Stop the local broker
    legarun docker stop mq

    # Publish the file to simulate a CentralEGA trigger
    MESSAGE="{ \"user\": \"${TESTUSER}\", \"filepath\": \"/${TESTFILE}.c4ga\"}"
    legarun ${MQ_PUBLISH} --correlation_id ${CORRELATION_ID} files "$MESSAGE"
    [ "$status" -eq 0 ]

    # Restart the local broker
    legarun docker restart mq
    legarun sleep 20

    # Check that a message with the above correlation id arrived in the expected queue
    # Waiting 20 seconds.
    retry_until 0 10 2 ${MQ_GET} v1.files.completed "${TESTUSER}" "/${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]

}

# MQ restarted, test delivery mode
# --------------------------------
# Message published at Central EGA but local broker down for a while
# When restarted, no messages are lost

@test "MQ delivery mode" {
    skip "Used after the update for MQ connection retries"
    TESTFILE=$(uuidgen)

    # Stop the verify component, so only ingest works
    legarun docker stop verify

    # Create a random file of {size} MB
    legarun dd if=/dev/urandom of=${TESTFILES}/${TESTFILE} count=1 bs=1048576
    [ "$status" -eq 0 ]

    # Encrypt it in the Crypt4GH format
    legarun lega-cryptor encrypt --pk ${EGA_PUB_KEY} -i ${TESTFILES}/${TESTFILE} -o ${TESTFILES}/${TESTFILE}.c4ga
    [ "$status" -eq 0 ]

    # Upload it
    legarun ${LEGA_SFTP} -i ${TESTDATA_DIR}/${TESTUSER}.sec ${TESTUSER}@localhost <<< $"put ${TESTFILES}/${TESTFILE}.c4ga /${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]

    # Fetch the correlation id for that file (Hint: with user/filepath combination)
    retry_until 0 100 1 ${MQ_GET} v1.files.inbox "${TESTUSER}" "/${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]
    CORRELATION_ID=$output

    # Publish the file to simulate a CentralEGA trigger
    MESSAGE="{ \"user\": \"${TESTUSER}\", \"filepath\": \"/${TESTFILE}.c4ga\"}"
    legarun ${MQ_PUBLISH} --correlation_id ${CORRELATION_ID} files "$MESSAGE"
    [ "$status" -eq 0 ]


    # Restart database
    legarun docker stop mq
    legarun docker restart mq
    legarun sleep 15

    # Check now that the delivery mode is still 2
    # And the messages are still there
    # Let it run its course
    
    # Restart verify
    legarun docker restart verify
    legarun sleep 15

    # Check that a message with the above correlation id arrived in the expected queue
    retry_until 0 10 2 ${MQ_GET} v1.files.completed "${TESTUSER}" "/${TESTFILE}.c4ga"
    [ "$status" -eq 0 ]
}