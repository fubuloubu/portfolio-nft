import pytest


@pytest.fixture(scope="session")
def sudo(accounts):
    return accounts[-1]


@pytest.fixture(scope="session")
def token(project, sudo):
    return sudo.deploy(project.dependencies["erc4626"].Token)


@pytest.fixture(scope="session")
def new_strategy(project, token, sudo):
    def create_strategy():
        return sudo.deploy(project.dependencies["erc4626"].VyperVault, token)

    return create_strategy


@pytest.fixture(scope="session")
def mint_tokens(token, sudo):
    def mint_tokens(account):
        token.mint(account, "100 ether", sender=sudo)

    return mint_tokens


@pytest.fixture(scope="session")
def portfolio(project, token, sudo):
    return sudo.deploy(project.Portfolio, token)
