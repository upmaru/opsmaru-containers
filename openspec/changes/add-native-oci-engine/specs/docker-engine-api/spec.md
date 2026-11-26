# Spec Delta

## ADDED Requirements

### Requirement: Engine selection at create

The host behaviour SHALL offer an optional callback that chooses `nested` or `native` for each container create, during admission and under the request deadline, given the classified request and the decoded create body. A missing callback, or a failing or late answer, SHALL select `nested`. A create routed to native that native cannot honour SHALL be refused with a Docker-shaped 400 naming each field and MUST NOT be sent to the nested engine. The library SHALL provide an eligibility check that returns the fields native cannot honour.

#### Scenario: Host without the callback

- **WHEN** a host does not implement the selection callback and a client runs `docker run IMAGE`
- **THEN** the container is created in the nested engine exactly as before this change

#### Scenario: No silent fallback

- **WHEN** the host selects native for a create that sets `HostConfig.Privileged`
- **THEN** the client receives a 400 naming the field and no container is created in either engine

### Requirement: Per-container routing

Every container-scoped and exec-scoped route SHALL be resolved to the engine that owns the referenced container or exec, by full ID, unique ID prefix or name. A reference that matches nothing SHALL produce the engine's not-found error. An ID prefix that matches containers in both engines SHALL produce the engine's ambiguous-reference error. Container routes in the route table SHALL record whether native containers are translated or refused, with a reason.

#### Scenario: Route follows the container

- **WHEN** one nested and one native container exist and a client runs `docker logs` on each
- **THEN** each request is served by the engine that owns that container

### Requirement: Merged container listing and names

Container listing SHALL merge the nested engine's containers with native containers, applying `all`, `limit`, `size` and the filters `id`, `name`, `label`, `status` and `ancestor` to both. Any other filter SHALL be refused with a Docker-shaped 400 while native containers exist. Container prune SHALL prune both engines and report the combined result. A container name SHALL be unique across both engines: a create with a name used in either engine SHALL produce the engine's name conflict error. The host SHALL serialize container creates per target.

#### Scenario: One list

- **WHEN** one nested and one native container are running and a client runs `docker ps`
- **THEN** both are listed

#### Scenario: Name taken in the other engine

- **WHEN** a nested container is named `web` and a client creates a native container named `web`
- **THEN** the client receives the name conflict error and no instance is created
