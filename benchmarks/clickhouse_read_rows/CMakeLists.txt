if (NOT TARGET dbms)
    message(FATAL_ERROR "clickhouse-read-rows must be added after ClickHouse declares the dbms target")
endif()

if (TARGET clickhouse-read-rows)
    return()
endif()

add_executable(clickhouse-read-rows "${CMAKE_CURRENT_LIST_DIR}/read_rows.cpp")
target_link_libraries(clickhouse-read-rows PRIVATE dbms)
